# Apache Fluss - Bilibili CI/CD & Cluster Operations Guide

本指南详细记录了 Apache Fluss 在 Bilibili 内部基础设施环境中的集群拓扑、构建 (Nyx)、发布 (Wave / Cloud-CD)、日常运维、监控巡检及重平衡 (Rebalance) 等全套 CI/CD 运维规范与操作指南。

---

## 1. 集群架构与节点拓扑

POC 预演集群标识为 **`jswj-kafka-test`**，应用标识为 **`infra.fluss.fluss`**，采用 5 节点分布式架构。

### 1.1 节点拓扑与服务分布

| 主机名 | 节点 IP | 部署角色 | Server ID | 监听端口 (Dual-Listener) | 指标端口 | 数据目录 |
| :--- | :--- | :--- | :---: | :--- | :---: | :--- |
| **`jswj-kafka-test-01`** | `10.84.16.12` | TabletServer | `1` | `INTERNAL:9125`, `CLIENT:9124` | `9250` | `/mnt/storage00/fluss/data`, `/mnt/storage01/fluss/data` |
| **`jswj-kafka-test-02`** | `10.84.16.26` | CoordinatorServer (Leader)<br>TabletServer<br>Flink Standalone JM/TM | `2` | Coordinator: `INTERNAL:9122`, `CLIENT:9123`<br>Tablet: `INTERNAL:9125`, `CLIENT:9124` | Coord: `9249`<br>Tablet: `9250`<br>Flink: `8081` | 同上（配置隔离：`conf/` vs `conf-coord/`） |
| **`jswj-kafka-test-03`** | `10.84.20.26` | TabletServer | `3` | `INTERNAL:9125`, `CLIENT:9124` | `9250` | 同上 |
| **`jswj-kafka-test-04`** | `10.84.20.30` | TabletServer | `4` | `INTERNAL:9125`, `CLIENT:9124` | `9250` | 同上 |
| **`jswj-kafka-test-05`** | `10.84.24.24` | TabletServer | `5` | `INTERNAL:9125`, `CLIENT:9124` | `9250` | 同上 |

### 1.2 核心基础组件与依赖

- **ZooKeeper 集群**：`10.84.16.12:2181,10.84.16.26:2181,10.84.20.26:2181,10.84.20.30:2181,10.84.24.24:2181/fluss`（chroot: `/fluss`）
- **远程分层存储 (HDFS)**：`remote.data.dir: hdfs://jscs-bigdata-ns37/kafka/fluss/jswj-kafka-test/remote`
- **Kerberos 认证**：
  - Keytab 路径：`/etc/security/keytabs/kafka.service.keytab`
  - Principal：`kafka/<hostname>@BILIBILI.CO`
  - NameNode Principal：`nn/_HOST@BILIBILI.CO`
- **安全与鉴权**：
  - 内部监听器 (`INTERNAL`): PLAINTEXT 协议
  - 客户端监听器 (`CLIENT`): SASL/PLAIN 协议（超级用户: `User:admin`，密码: `admin-pass`）
- **JDK 运行时**：统一使用 OpenJDK 17 (`/data/sdk/jdk17`)，启动脚本自动注入 JVM `--add-opens` 参数。

---

## 2. CI 构建流程 (Nyx Build)

Apache Fluss 接入 Bilibili Nyx 声明式构建平台 (Nyx v2)。

### 2.1 构建元数据

- **平台标识**：`appid: infra.fluss.fluss`，`app_id: 18881`
- **源码仓库**：`git@git.bilibili.co:datacenter/fluss.git`（GitLab Project ID: `53657`）
- **构建环境定义**：`.bilibili-ci/Dockerfile`
  - 基础编译镜像：`hub.bilibili.co/nyx-compile/bili-maven:3.9.7-openjdk-11`
  - 编译执行脚本：`.bilibili-ci/build.sh`（多阶段构建输出二进制 tarball、`bilibili-cicd` 运维脚本与 `flink-connectors` 依赖）
- **输出格式 (CRITICAL)**：必须为 **`export_type: artifact`**。
  - 产物命名格式：`infra.fluss.fluss_<commit_sha>_<timestamp>-normal.tar.gz`
  - 只有导出为 `artifact` 类型的包才会自动进入 Wave / Cloud-CD 软件包列表，供物理机发布使用；如导出为 `image` 则无法在物理机上发布。

### 2.2 触发 Nyx 构建命令

使用项目内置的 `nyx-build` 运维脚本触发与轮询：

```bash
# 1. 触发构建（需确保不要受外部 SOCKS5 代理影响）
env -u ALL_PROXY -u all_proxy -u http_proxy -u https_proxy \
node ~/.codex/skills/bili-nyx/scripts/nyxBuild.js trigger \
  --appid=infra.fluss.fluss \
  --app_id=18881 \
  --branch=main \
  --dockerfile-path=.bilibili-ci/Dockerfile \
  --export-type=artifact

# 2. 查询构建进度与产物详情
env -u ALL_PROXY -u all_proxy -u http_proxy -u https_proxy \
node ~/.codex/skills/bili-nyx/scripts/nyxBuild.js status \
  --appid=infra.fluss.fluss \
  --build-id=<BUILD_ID>
```

> **构建耗时参考**：由于 Fluss 模块较多，Nyx 容器内编译与打包耗时约 4~5 分钟。构建成功后状态为 `status: 2`。

---

## 3. CD 发布上线流程 (Wave / Cloud-CD)

物理机部署通过 Bilibili Wave 平台（Cloud-CD）执行滚动发布。

### 3.1 Wave 服务标识

- **TabletServer 发布服务**：`app_service_id: 10285`（名称：`fluss`，部署根目录：`/data/service/`，包含全部 5 个节点）
- **CoordinatorServer 发布服务**：`app_service_id: 10286`（名称：`fluss-corrdinator`，部署根目录：`/data/service/fluss`，仅 Node 2）

### 3.2 部署执行流程与钩子机制

发布时 Wave 会依次在各主机上执行以下流水线阶段：
1. **`StagePullPackage`**：从对象存储 (BOSS) 拉取 `infra.fluss.fluss_<commit>_<ts>-normal.tar.gz` 到 `/data/publish/fluss/code/<RECORD_ID>/`。
2. **`StageReleasePackage`**：解压 tarball，释放 `fluss/` 运行目录及 `bilibili-cicd/` 部署脚本。
3. **`StageRunPreScript`**（[`bilibili-cicd/pre_deploy.sh`](bilibili-cicd/pre_deploy.sh)）：
   - 根据环境变量 `FLUSS_ROLE`（默认为 `tablet`）精准下线目标服务 (`systemctl stop fluss-tablet-server`)，避免误杀同机运行的 Coordinator。
4. **`SwitchSymlink`**：切换系统软链接：
   ```bash
   rm -rf /data/service/fluss && ln -s /data/publish/fluss/code/<RECORD_ID>/fluss /data/service/fluss
   ```
5. **`StageRunPostScript`**（[`bilibili-cicd/post_deploy.sh`](bilibili-cicd/post_deploy.sh)）：
   - 解析本机主机名后缀（如 `test-01` -> ID `1`）自动配置 `tablet-server.id`。
   - 读取并初始化 Kerberos Ticket Cache (`kinit`)。
   - 将当前机器 IP 写入 `advertised.listeners`。
   - 自动准备 `conf-coord/` 隔离配置（针对 Node 2 Coordinator）。
   - 初始化 systemd unit 与 drop-in 配置（[`bilibili-cicd/init_systemd.sh`](bilibili-cicd/init_systemd.sh)）。
   - 重启 systemd 服务单元并验证进程存活与端口就绪。
6. **`StageHealthCheck`** & **`StageRunCleanOldVersion`**：健康检查并清理历史旧版本（默认保留 5 个版本）。

### 3.3 推荐滚动发布命令

推荐使用 `wavePublish.js` 逐台节点滚动发布（建议遵循 **先 Follower 节点，后 Leader 节点** 顺序），配合 `--no-wait` 避免批次冷却阻塞：

```bash
# 单节点精准发布命令模板（--hosts 指定单个主机名，避免多批次停顿）
node ~/.codex/skills/wave-publish/scripts/wavePublish.js \
  --app-service-id=10285 \
  --package-id=<BUILD_ID> \
  --hosts=<TARGET_HOSTNAME> \
  --no-wait

# 推荐发布顺序：
# 1. jswj-kafka-test-05 (无 Leader 纯 Follower 扩容节点)
# 2. jswj-kafka-test-04
# 3. jswj-kafka-test-03
# 4. jswj-kafka-test-02 (核心混布节点，只重启 TabletServer)
# 5. jswj-kafka-test-01 (原 Leader 集中节点)
```

> **查询 Wave 发布进度**：
> ```bash
> # 单次查询当前发布状态与阶段明细
> node ~/.codex/skills/wave-publish/scripts/wavePublish.js --record-id=<RECORD_ID>
> 
> # 或使用实时监控（--watch 轮询直至发布结束）
> node ~/.codex/skills/wave-publish/scripts/checkDeployStatus.js <RECORD_ID> --watch
> ```

---

## 4. 集群日常运维与巡检操作

### 4.1 机器远程执行规范 (`bili-remote-exec`)

访问机器执行命令统一使用 `immedTask.js` 工具。**注意必须显式移除外部代理环境变量**：

```bash
env -u ALL_PROXY -u http_proxy -u https_proxy \
node ~/.codex/skills/bili-remote-exec/scripts/immedTask.js \
  '<COMMAND>' <HOST_OR_IP> --wait --log
```

### 4.2 访问内网 HTTP / Prometheus 指标

访问机器上的 Prometheus 端口（`9249`/`9250`）或 Flink UI（`8081`）时，**必须通过内网 SOCKS5 代理**：`10.157.82.18:9090`。

```bash
# 查看 Coordinator 核心健康指标
curl -s --socks5-hostname 10.157.82.18:9090 http://10.84.16.26:9249/metrics | \
  grep -E "offlineBucketCount|activeCoordinatorCount|activeTabletServerCount"

# 巡检所有节点欠副本 (underReplicated) 指标
for ip in 10.84.16.12 10.84.16.26 10.84.20.26 10.84.20.30 10.84.24.24; do
  echo "--- Node $ip ---"
  curl -s --socks5-hostname 10.157.82.18:9090 http://$ip:9250/metrics | grep "^fluss_tabletserver_underReplicated"
done

# 巡检各节点 Leader 数量分布
for ip in 10.84.16.12 10.84.16.26 10.84.20.26 10.84.20.30 10.84.24.24; do
  echo "--- Node $ip ---"
  curl -s --socks5-hostname 10.157.82.18:9090 http://$ip:9250/metrics | grep "^fluss_tabletserver_leaderCount"
done
```

### 4.3 集群健康深度探活 (`ClusterHealthReadinessCheck`)

在 `10.84.16.26` 上直接执行内置探活工具：

```bash
/data/sdk/jdk17/bin/java -cp "/data/service/fluss/lib/*" \
  org.apache.fluss.server.tools.ClusterHealthReadinessCheck \
  --host 10.84.16.26 --port 9125
```
正常输出示例：
```
[readiness-check] status=0 numReplicas=330 inSyncReplicas=330 numLeaderReplicas=110 activeLeaderReplicas=110
```

---

## 5. 集群重平衡运维 (Rebalance)

当集群扩缩容、节点重启导致 Leader 倾斜或副本不均时，需触发 Rebalance。

### 5.1 Java Admin Client 触发重平衡

在 `10.84.16.26` 上，使用 Fluss 客户端 Jar 运行重平衡工具：

```java
// RebalanceTool.java
import org.apache.fluss.client.Connection;
import org.apache.fluss.client.ConnectionFactory;
import org.apache.fluss.client.admin.Admin;
import org.apache.fluss.cluster.rebalance.GoalType;
import org.apache.fluss.cluster.rebalance.RebalanceProgress;
import org.apache.fluss.cluster.rebalance.RebalanceStatus;
import org.apache.fluss.config.Configuration;

import java.util.Arrays;
import java.util.Optional;

public class TriggerRebalance {
    public static void main(String[] args) throws Exception {
        Configuration conf = new Configuration();
        conf.setString("bootstrap.servers", "10.84.16.26:9123");
        conf.setString("client.security.protocol", "SASL");
        conf.setString("client.security.sasl.mechanism", "PLAIN");
        conf.setString("client.security.sasl.username", "admin");
        conf.setString("client.security.sasl.password", "admin-pass");

        try (Connection conn = ConnectionFactory.createConnection(conf);
             Admin admin = conn.getAdmin()) {
            String id = admin.rebalance(Arrays.asList(
                    GoalType.REPLICA_DISTRIBUTION,
                    GoalType.LEADER_DISTRIBUTION
            )).get();
            System.out.println("Rebalance submitted ID: " + id);

            while (true) {
                Optional<RebalanceProgress> opt = admin.listRebalanceProgress(id).get();
                if (opt.isPresent()) {
                    RebalanceProgress p = opt.get();
                    System.out.println("Status: " + p.status() + " Progress: " + p.formatAsPercentage());
                    if (RebalanceStatus.FINAL_STATUSES.contains(p.status())) {
                        break;
                    }
                }
                Thread.sleep(2000);
            }
        }
    }
}
```

编译与运行命令：
```bash
/data/sdk/jdk17/bin/javac -cp "/data/service/fluss/lib/*:/data/publish/fluss/code/<CURRENT_RELEASE>/flink-connectors/*" /tmp/TriggerRebalance.java
/data/sdk/jdk17/bin/java -cp "/tmp:/data/service/fluss/lib/*:/data/publish/fluss/code/<CURRENT_RELEASE>/flink-connectors/*" TriggerRebalance
```

### 5.2 Flink SQL 存储过程触发

也可在 Flink SQL Client 中直接调用内置存储过程：
```sql
-- 触发副本与 Leader 均衡
CALL sys.rebalance('REPLICA_DISTRIBUTION,LEADER_DISTRIBUTION');

-- 查看重平衡进度
CALL sys.list_rebalance();

-- 取消正在进行的重平衡（如有必要）
CALL sys.cancel_rebalance();
```

---

## 6. 关键避坑与运维禁忌

1. **Wave 发布期间严禁并发执行 `immedTask.js`**：
   - Bilibili 主机 Agent 对原子任务执行互斥锁。如果 Wave 在执行 `SwitchSymlink` 或脚本阶段时，外部脚本向该节点提交了 `immed_task`，会导致 Wave 任务排队超过 60 秒触发 `job timeout` 导致发布中断。
2. **Nyx 构建必须指定 `export_type: artifact`**：
   - 默认的 `image` 导出格式仅适合容器化 K8s 部署；物理机 Wave 发布必须产生 `.tar.gz` 格式的包。
3. **Node 2 混布节点的角色安全保护**：
   - `jswj-kafka-test-02` 上同时运行 CoordinatorServer 与 TabletServer。`server.yaml` 对应 Tablet，`conf-coord/server.yaml` 对应 Coordinator。发布 Tablet 时必须确认 `FLUSS_ROLE=tablet`，绝对禁止误杀 Coordinator。
4. **多磁盘 `disk.properties` 隔离防漂移**：
   - 集群采用 `/mnt/storage00/fluss/data` 与 `/mnt/storage01/fluss/data` 多挂载点。每个目录下均有 `disk.properties` 记录 `server.id`。禁止跨机器直接 rsync 数据目录，否则会导致 Server ID 冲突而拒绝启动。
5. **副本拉取参数与网络流量控制**：
   - `log.replica.fetcher-number` 建议保持为 4（不建议过大增加网卡与 CPU 开销）。
   - `log.replica.max-lag-time` 建议保持为 60s，为物理网卡短时突发争抢留出缓冲区，避免频繁触发 ISR Shrink/Expand 震荡。
