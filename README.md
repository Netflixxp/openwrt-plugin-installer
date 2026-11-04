# OpenWrt 插件安装助手

在路由器的 SSH 终端里，选一个插件编号，确认后就能下载安装。脚本会识别固件版本和软件包架构，并为当前网络选择 GitHub 下载线路。

## 快速开始

用 **root** 账号 SSH 登录路由器，然后执行：

```sh
cd /tmp
curl -fL --connect-timeout 5 --max-time 30 \
  https://raw.githubusercontent.com/Netflixxp/openwrt-plugin-installer/main/openwrt-plugin-install.sh \
  -o openwrt-plugin-install.sh && sh openwrt-plugin-install.sh
```

如果路由器无法下载脚本，可以在电脑上打开 [脚本页面](https://github.com/Netflixxp/openwrt-plugin-installer/blob/main/openwrt-plugin-install.sh)，下载原始文件，用 SCP 或 SFTP 上传到路由器的 `/tmp`，再运行：

```sh
sh /tmp/openwrt-plugin-install.sh
```

菜单会显示当前设备可用的插件版本。输入编号选中插件，输入 `y` 开始，直接回车取消，菜单中输入 `0` 退出。

## 支持范围

| 固件版本 | 安装包类型 |
| --- | --- |
| OpenWrt 24.x 及使用相应版本号的衍生固件 | opkg |
| OpenWrt 25.12.x 及使用相应版本号的衍生固件 | apk |

脚本会同时检查固件版本、实际包管理器和软件包架构。iStoreOS、ImmortalWrt 等衍生固件能否安装，取决于设备上的软件源和上游有没有为对应架构提供安装包。

菜单包含 **PassWall、PassWall2、OpenClash、SSRP、Nikki、HomeProxy 和 dae**。安装包来自 [CloudRunFilesBuilder Releases](https://github.com/wkccd/CloudRunFilesBuilder/releases)。菜单中的「最新版」指该仓库最新一期发布中与当前设备匹配的版本。最新一期缺包时，脚本额外查询最近 10 期发布，选择同架构、同包管理器且提供 SHA-256 的最新历史包，并标明发布日期。查询失败或没有符合条件的包时，会显示「暂无可用版本」。

## 加速和安装流程

1. **识别设备。** 自动读取固件和软件包架构。
2. **查询版本。** 4 条内置线路并行查询 GitHub 发布接口，最多约 8 秒。采用最快返回有效发布信息的线路。
3. **确认下载。** 优先沿用查版本时选中的线路。内置线路查询失败，或选中的内置线路下载、校验失败时，会尝试[在线候选列表](https://yishijie.gitlab.io/ziyuan/)。候选也失败时，最后尝试 GitHub 直连一次。
4. **显示进度。** 下载时显示百分比、速度和预计剩余时间。单条下载线路最多等待 5 分钟。安装耗时取决于设备和依赖下载情况。
5. **校验并安装。** 检查文件大小和 SHA-256，把 `/etc/config` 备份到 `/root/openwrt-plugin-backup.*/config.tar.gz`，再以 root 执行上游安装包。备份包含路由器配置，软件包及其依赖需要通过对应软件源恢复。

若版本信息和校验值来自第三方节点，确认安装前会显示节点地址。此时文件校验依赖该节点提供的信息，请只在信任该节点时继续。

## 常用命令

| 命令 | 用途 |
| --- | --- |
| `sh openwrt-plugin-install.sh` | 打开安装菜单 |
| `sh openwrt-plugin-install.sh --info` | 查看本机固件版本、架构和包管理器 |
| `sh openwrt-plugin-install.sh --list` | 查询并列出当前设备可用版本 |
| `sh openwrt-plugin-install.sh --dry-run openclash` | 预检 OpenClash 的安装包匹配结果 |
| `sh openwrt-plugin-install.sh passwall2` | 直接选择 PassWall2，确认后安装 |
| `sh openwrt-plugin-install.sh --verbose --list` | 显示包名和发布信息来源，便于排查 |
| `sh openwrt-plugin-install.sh --help` | 查看完整参数 |

`--list` 和 `--dry-run` 会联网查询发布信息。安装模式需要 root 权限和足够的 `/tmp` 可用空间。

## 常见问题

**提示缺少命令怎么办？**  
安装流程需要 `curl`、`jsonfilter`、`sha256sum` 和 `base64`。请根据报错，通过当前固件的软件源补齐缺少的命令后重试。

**插件装过了，还能用这个脚本更新吗？**  
可以选同一个插件并确认，脚本会执行当前匹配的上游安装包。菜单展示的是发布版本，已安装版本请在路由器后台查看。

**查询、下载或校验失败怎么办？**  
先确认路由器本身能联网，然后用 `--verbose --list` 排查版本查询。若下载或安装报错，可用 `--verbose 插件名` 复现并查看线路和上游安装输出。

## 反馈

欢迎在 [GitHub Issues](https://github.com/Netflixxp/openwrt-plugin-installer/issues) 反馈。请附上路由器型号、`--info` 输出、所选插件和完整错误提示。分享日志前请移除密码、订阅地址等敏感信息。
