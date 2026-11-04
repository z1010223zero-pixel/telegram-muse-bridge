# Telegram Muse Bridge

用自建 Telegram Bot 连接 [Muse](https://muse.ai) 个人 AI 助手，在 Telegram 里直接跟你的 Muse 对话。

Bridge your personal Muse AI assistant to Telegram with a bot you own. Tested on a real setup, 2026-11-04.

> 这份仓库分享的是**方法**，不是某个现成的 Bot。你按下面步骤建自己的 Bot、换成自己的 ID，就能复用。

## 它能做什么

- **在 Telegram 里用 Muse**：发文字就像在 Muse 里聊天一样，追问有上下文，不用每次从头说起。
- **连续对话**：每个聊天单独存一份 per-chat 状态（摘要 + 最近约 20 轮 + 独立的待办清单），新消息先读状态再回答；写回时先写临时文件再原子覆盖。
- **桥本地命令**（仅白名单用户）：`/todos` 列未完成待办，`/status` 报会话起始时间、已记录轮数和未完成待办数，`/new` / `/reset` 开新会话（清空摘要和轮次、保留待办，开新会话前自动归档上一会话）。
- **聊天内审核**：需要你本人确认的动作，助手发一条带「✅ 同意 / ❌ 拒绝」按钮的消息，点按即决定；审核 30 分钟过期、超时默认拒绝、只认白名单点击、点完撤按钮。
- **收发媒体**：图片下载后查看，不再以空文字到达；语音、文档、视频、音频都能收（语音能否转写取决于当次有没有可用转写工具，没有就存好并如实告知，不当空消息丢掉）；能往 Telegram 发文件和图片。
- **长消息自动分段**：超 4000 字符自动按段落、换行切分顺序发送，不丢内容。
- **在场感**：先发 typing，耗时任务发「⏳ 处理中…」状态消息并按步骤更新进度，完成时编辑成完成标记。
- **实时性**：长轮询（`get-updates --timeout 25`，hook 间隔 5 秒），消息到达约 1–2 秒即被带回唤醒；不需要公网入口，不迁 webhook，空轮询不唤醒助手。
- **相册聚合**：同一 `media_group_id` 的成组照片/视频凑成一轮合并理解、只回复一次。
- **群与话题**：按 `message_thread_id` 分话题存状态，待办按话题隔离；可指定一个多 bot 协作群为例外（见下文）；策略开关默认全关（按群策略、昵称唤醒、会话级 `/activation`、自动重置会话）。

## 工作原理

```text
Telegram ──长轮询 getUpdates──> hook 脚本 ──有新消息才唤醒──> Muse
                                                            │
Telegram <── telegram_bot.py (Bot API) ── 回复/发文件/审核按钮 ──┘
```

- 没有 webhook，不需要公网入口、隧道或额外账号。
- 轮询脚本只做一件事：拉取更新、保存 offset、把新消息交给助手；空轮询不唤醒、不花额度。
- 一个 Bot 同一时间只能接一个 Muse，也只能有一个 `getUpdates` 轮询者在消费消息。不要把同一个 Bot 再接给 OpenClaw 等其他接入。

## 仓库结构

```text
.
├── README.md                                  # 本文件
├── LICENSE                                    # MIT
├── custom-skills/telegram-muse-bridge/
│   ├── SKILL.md                               # 通用 Skill：自建 Bot、连接器、轮询桥接、白名单
│   └── skill.yaml
├── custom-connectors/custom.telegram-bot/
│   ├── CONNECTOR.md                           # 连接器文档：全部命令的用法
│   ├── connector.yaml
│   └── bin/telegram_bot.py                    # Bot API helper：收发消息/媒体/文件/审核/反应/命令菜单
├── hooks/
│   ├── telegram-bridge.template.sh            # 轮询脚本模板（改名、替换占位符后使用）
│   ├── telegram-bridge.template.json          # hook 定义模板，含完整唤醒规则 1–17
│   └── search-history.py                      # 历史检索小工具：按关键词搜状态与归档
└── telegram-bridge/
    └── config.template.json                   # 策略开关配置模板，四个功能开关默认全关
```

## 快速开始

### 1. 建自己的 Bot

在 Telegram 里找 @BotFather，用 `/newbot` 创建一个只属于自己的 Bot，妥善保管它返回的 token，**不要转发给别人，也不要贴进聊天记录、Skill、脚本或日志**。

### 2. 在 Muse 里新建连接器

新建自定义连接器 `custom.telegram-bot`，服务商为 `telegram-bot`，认证为 `api_key`，token 放在 URL 路径段 `/bot{}/` 中，主机为 `api.telegram.org`。

把本仓库 `custom-connectors/custom.telegram-bot/` 下的 `CONNECTOR.md`、`connector.yaml` 和 `bin/telegram_bot.py` 放到自己工作区对应位置。

用 `get-me` 做一次无害读取，确认返回的是自己的 Bot 身份，再给自己发一条测试消息：

```bash
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py get-me
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py send-message --chat-id <你的 chat_id> --text "测试"
```

> 坑点：不要用会把替代凭证冒号做百分号编码的通用 URL 拼接办法，否则 Telegram 会返回 404。须把原始替代凭证直接放进 `/bot{}/` 路径段。

### 3. 搭轮询桥接

把 `hooks/` 下的轮询脚本和 hook 定义按模板放好（脚本改名为 `telegram-bridge.sh` 放到 `~/hooks/scripts/` 下），替换模板里的占位符：

- 脚本中的 `YOUR_BOT_USERNAME`（共三处）换成自己 Bot 的用户名；
- hook 模板中的 `__MULTI_BOT_GROUP_CHAT_ID__` 换成自己的多 bot 协作群群号，不用多 bot 群功能可整段删掉规则 13；
- 投递目标按自己 Muse 的会话情况设置。

脚本和 hook 须保存一份 allowlist，**只放自己的 Telegram 用户 ID**。非白名单发来的消息一律不执行，只回一句这是私人 Bot、配对需主人批准，并把对方信息报给主人等批准。

### 4. 放策略配置

把 `telegram-bridge/config.template.json` 放到自己的 `~/workspace/telegram-bridge/config.json`（权限 0600），群号换成自己的，**四个开关先保持全关**。只有明确确认后才打开某个开关。

### 5. 注册命令菜单

```bash
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py set-commands
python3 ~/workspace/custom-connectors/custom.telegram-bot/bin/telegram_bot.py get-commands
```

注册一次即可，之后在 Telegram 输入框打 `/` 就能弹出 `/todos`、`/status`、`/new`、`/reset` 菜单。

接通后先跑一遍：发文字、发图片（附文字说明）、试 `/status`，确认助手下载图片后连同说明一起处理。

## 连接器命令一览

`bin/telegram_bot.py` 提供的全部命令（详见 `custom-connectors/custom.telegram-bot/CONNECTOR.md`）：

| 命令 | 作用 |
| --- | --- |
| `get-me` | 无害读取，确认 Bot 身份 |
| `get-updates [--offset N] [--timeout S]` | 拉取新消息，支持长轮询 |
| `send-message --chat-id --text [--reply-to-message-id]` | 发文字，超长自动分段 |
| `send-chat-action --chat-id` | 发 typing 在场感 |
| `edit-message --chat-id --message-id --text` | 改写已发消息（进度更新、完成标记） |
| `send-file / send-photo-file --chat-id --path [--caption]` | 发文件 / 发图片（>45 MB 直接拒绝） |
| `get-file / download-file --file-id` | 解析并下载收到的媒体 |
| `send-approval --chat-id --text --approval-id` | 发带 ✅/❌ 按钮的审核消息 |
| `answer-callback --callback-query-id` | 回执按钮点击 |
| `remove-keyboard --chat-id --message-id` | 撤掉审核按钮，防重复点击 |
| `set-commands / get-commands` | 注册 / 读回命令菜单 |
| `react --chat-id --message-id [--emoji]` | 给消息加表情反应 |

## 安全说明

- **Token 只通过 Muse 的安全连接流程保存**，绝不出现在仓库、聊天记录、脚本、命令参数或日志里。助手只使用替代凭证调用 `api.telegram.org`。
- **白名单是唯一入口**：只有 allowlist 里的 Telegram 用户 ID 发来的消息才会被当作主人的指令执行；其他人只收到私人 Bot 的提示，主人会收到一条配对请求报告。
- **一个 Bot 只接一个 Muse**：不要把同一个 Bot 同时接给 OpenClaw 或其他接入，两个轮询者会抢消息。
- **Telegram 审核替代不了平台批准**：Telegram 里的 ✅ 同意只是主人对桥下一步动作的确认；购买、对外发送等动作若平台要求在 Muse 内批准，仍以 Muse 内的批准为准。
- **有副作用的动作失败或结果不明时不自动重试**，相关记录标 `unknown`，等主人确认后再继续。
- **状态文件权限**：per-chat 状态与归档默认目录 0700、文件 0600；那是使用者的私人记录，不属于分享内容。

## 群使用注意（实测教训）

- 普通群里 Bot 不是管理员时，Telegram 只送达命令、回复 Bot 本人的消息和系统消息，纯文字 @ 不送达。**要在群里用 @ 唤醒，先把 Bot 设为群管理员。**
- 给 Bot 设管理员等操作会触发 Telegram 把普通群自动升级为超级群，`chat_id` 随之改变：hook 规则里写死的群号（多 bot 协作群那条）和对应的 per-chat 状态文件名都要同步改成新群号，旧群号发消息会直接报错。
- 多 bot 协作群（规则 13）只放开指定的一个群、只放开 bot 发送者，带四条护栏：bot 的话不算主人指令、无真人介入时连聊最多 3 轮、不回复自己、群里真人非白名单成员仍不执行。**不用这个功能就把规则 13 整段删掉。**

## 限制与常见问题

- Bot 只能回复先给它发过消息的聊天，不能主动给从没找过它的人发消息。
- 语音转写取决于当次有没有可用转写手段（本地 whisper / faster-whisper 类工具，或确实能用的转写服务）；没有时音频会存好并如实告知，不会默默丢掉。
- typing 约 5 秒过期，属 best-effort 在场感，不要为了刷新它打断正事。
- 错误类回复按 chat 冷却 60 秒，避免刷屏；只读查询类失败可重试一次。
- 上下文按 token 封顶：recent 内容估算超过约 24000 token 时触发滚动摘要、保留尾部约 8000 token（不多于最近 12 轮）；触发前先把耐久事实 flush 进当天记忆日记的「Telegram 桥 flush」小节。
- 历史检索：`/new`、`/reset` 前先把当前会话快照归档到 `archive/<chat_id>/<session_id>.json`，用 `hooks/search-history.py <关键词>` 检索全部状态与归档。

## 里面没有、也不要发的东西

- 发送者的 Bot 用户名、Bot ID、token、Telegram 用户 ID、聊天 ID，以及 hook 状态里的 offset 与 allowlist。
- 任何真实 token 都不应该出现在这里。
- 任何人的 per-chat 状态文件、会话 ID、对话摘要和待办内容。

## License

MIT，见 [LICENSE](LICENSE)。
