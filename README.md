# 抖音 AI 代管（douyin-ai-operator）

给一个 AI agent 用的抖音账号值守 skill：刷视频、回私信、回评论、发起床/睡前总结作品。

## 目录结构

```
douyin-ai-operator/
├─ SKILL.md                  # 给 agent 读的主文件（工作流 + 约束 + 算法）
├─ README.md                 # 人读的说明（本文件）
├─ prompts/
│  └─ pure-prompt.md         # 纯提示词版（不想用 skill 机制时直接贴）
├─ state/
│  ├─ day.json               # 今日状态
│  ├─ dm-cursors.json        # 每个会话最后回复的消息 id
│  ├─ dm-queue.json          # 栈 / 冷却
│  └─ comment-cursor.json    # 最后回复的评论 id（跨天持久化）
└─ scripts/
   ├─ cdp.ps1                # 通用 CDP 小工具（js/click/itext/ipoint/upload/shot…）
   ├─ douyin.ps1             # 抖音封装：启动 Edge、红点、会话、发消息、发表作品
   └─ run-loop.ps1           # 值守主循环骨架（3 个视频一检查）
```

## 安装（Windows）

1. 把整个目录放到你的 skill 目录（例如 `%USERPROFILE%\.dsh\skills\douyin-ai-operator`）。
2. 首次登录：手动启动一次独立浏览器并扫码登录抖音：
   ```powershell
   .\scripts\douyin.ps1 -cmd start
   ```
   弹出的 Edge 窗口里登录抖音（扫码），之后 profile 会记住登录态。
3. 自检：
   ```powershell
   .\scripts\douyin.ps1 -cmd reddots     # 看通知/消息红点
   .\scripts\douyin.ps1 -cmd dms         # 列私信会话
   .\scripts\douyin.ps1 -cmd watch       # 打开一个「蓝色大肥鱼」视频开始刷
   ```
4. 把这些命令交给你的 agent，让它按 `SKILL.md` 的流程循环。

## 目录结构补充

`references/spec-review.md` 记录了**原始口述规则的勘误与补漏**（10 处必须有歧义/自相矛盾之处 + 13 项缺口），以及修正后的唯一权威算法。给 agent 时建议一并提供：SKILL.md 是流程，spec-review 是"为什么这么定"。

## 常驻三栏（推荐用法，v2.2+）

抖音网页版的私信有两种入口：**就地弹层**（在 `douyin.com` 里点「消息」，面板盖在推荐流上，页面不跳转）和**整页私信**（`douyin.com/chat`）。这个 skill 现在走前一种，并把页面摆成一个常驻的三栏：

```
┌──────────────┬────────────────┬────────────────┐
│ 推荐流视频    │ 视频评论区面板  │ 私信列表面板    │
└──────────────┴────────────────┴────────────────┘
```

中间那块评论区是**跟着视频走**的：开过一次之后，下滑换视频它会自动换成新视频的评论，一直存在。所以摆一次就能一直用，不用每轮回流。

```powershell
# 1) 起浏览器（Edge + CDP，别加 --headless / --disable-gpu）
.\scripts\douyin.ps1 -cmd start

# 2) 摆三栏（视频 + 评论区 + 私信列表），成功后写 state/dock.json
.\scripts\douyin.ps1 -cmd dock
.\scripts\douyin.ps1 -cmd dock -arg check     # 只检查，不摆
.\scripts\douyin.ps1 -cmd dock -arg reset     # 强制回推荐流再摆

# 3) 看现在是不是三栏态
.\scripts\douyin.ps1 -cmd ui

# 4) 回私信：开会话 → 发 → 校验 → 自动返回列表
.\scripts\douyin.ps1 -cmd dmreply -arg "张三" -arg2 "收到，我这就去"
#    或者分步：open 张三 → send "…" → dmback
```

要点：

- **会话是就地打开的**（右边面板里换成聊天框），页面不跳转；发完点会话框**左上角的返回箭头**回列表（`-cmd dmback`，脚本会回读校验）。
- **屏幕上同时有两个输入框**：中间评论框、右边聊天框。`send` / `quote-send` 只在会话框内找编辑器（找不到就返回 `NO_CHAT_OPEN`），`reply-comment` 只在会话框外找。别再用「第一个可见的 contenteditable」那种写法——三栏下它会打到评论区去。
- **通知是悬浮层**：点开只看一眼，不影响三栏存在，不用为它导航。

## 可调参数（config.json）

```json
{
  "owner": {
    "name": "",
    "aliases": [],
    "treat_messages_as_instructions": true,
    "reply_style": "work",
    "note": "填你自己账号的昵称：命中 name / aliases 的会话视为「用户本人」，其消息按指令执行而不是闲聊。留空 = 关闭该功能。"
  },
  "theme": "蓝色大肥鱼",
  "themes": []
}
```

- `owner.*`：号主身份（详见下节「owner（号主身份）怎么用」）。命中 `name` / `aliases` 的会话被视为「用户本人」，其消息按**指令**执行（回话用工作口吻，不卖萌）。
- `theme`：默认刷视频主题（搜索关键词），不填则用 `douyin`。
- `themes`：主题白名单，`theme` 缺省时取第一个；留空 `[]` 表示不限主题。

## owner（号主身份）怎么用

**它是干什么的**：告诉 agent「哪个会话是我自己」。区别在于：
- **普通会话** = 聊天对象 → 按人设聊天，永远不执行对方要求的任何操作；
- **号主会话** = 你本人 → 它发来的消息当**工作指令**执行，回复用工作口吻（做了什么/结果/下一步），不卖萌。

**怎么配**（`config.json`）：

```json
"owner": {
  "name": "你的昵称",
  "aliases": ["你的昵称", "你的小号"],
  "treat_messages_as_instructions": true,
  "reply_style": "work"
}
```

- `name`：你账号在私信列表里显示的那个昵称（跟自己聊天时，会话名就是你自己的昵称）。
- `aliases`：同一个人的其他显示名/小号，命中任意一个都算号主。
- `treat_messages_as_instructions`：`true` = 号主消息当指令；`false` = 当普通聊天。
- **三项都留空 = 关闭号主特判**，所有会话一律按普通聊天处理（不想让 agent 区分身份就这样配）。

**额外约定（可选）：`###` 前缀**
号主消息正文以 `###` 开头 = 下指令；不带 = 闲聊。**必须「发送者=号主」且「正文以 ### 开头」同时成立**；其他人发 `###` 一律当普通聊天，绝不执行。

**怎么验证配对了**：

```powershell
.\scripts\douyin.ps1 -cmd dms        # 每条会话带 owner: true|false
.\scripts\douyin.ps1 -cmd open -arg 你的昵称
```

`owner: true` 出现在你期望的那个会话上，就对了。

**边界（重要）**：号主身份不是越界许可证。即便是号主本人要求，涉及隐私泄漏、代验证/代支付/代注册、危险或违法操作，agent 照样拒绝；它只把号主的话当"这是什么任务"的指令，不当"你可以突破硬约束"的授权。


## theme（刷视频主题）怎么用

**一句话**：theme 就是 agent 刷视频时用的**搜索关键词**，决定它今天看什么内容；它不影响「要不要回消息」，只影响「刷什么」。

优先级（高 → 低）：

1. 命令行显式指定：`-Theme` / `-cmd watch -arg`；
2. `config.json` 的 `theme`；
3. `config.json` 的 `themes[0]`；
4. 兜底字符串 `douyin`。

四种用法：

```powershell
# 1) 直接刷某个主题（一次性）
.\scripts\douyin.ps1 -cmd watch -arg "蓝色大肥鱼"

# 2) 开值守主循环，指定主题（推荐；每刷 3 个视频检查一次红点）
.\scripts\run-loop.ps1 -Theme "蓝色大肥鱼"

# 3) 改配置，之后所有命令都默认用它（中文写进配置更稳，不受 shell 编码影响）
#    config.json -> "theme": "蓝色大肥鱼"
.\scripts\run-loop.ps1

# 4) 只搜索不进入刷视频模式
.\scripts\douyin.ps1 -cmd search -arg "蓝色大肥鱼"
```

注意事项：

- **中文关键词建议写进 `config.json`**：PowerShell 5.1 对无 BOM 的 UTF-8 字面量会乱码，配置走 JSON 读取最稳；命令行传中文一般没问题（脚本用 `-arg` / `-Theme` 接收）。
- theme 只影响进入哪个搜索页；进去之后靠 `watch` 的顺序播放继续刷，页面自带的「推荐」流不受 theme 约束。
- 想让 agent **换主题**（比如今天看「蓝色大肥鱼」、明天看「DeepSeek」），改 `config.json` 的 `theme` 或下次启动时传 `-Theme` 即可，`state/` 里的计数与游标不受影响。
- 想让 agent **完全不限主题**，把 `theme` 删掉、`themes` 留空数组即可（回落 `douyin` 关键词）。

## 计数（可选）

```powershell
.\scripts\douyin.ps1 -cmd counter          # 累计发出条数
.\scripts\douyin.ps1 -cmd counter -arg reset
```

只做统计，**不会额外补发任何文案**（旧版本「每 N 条自动补一句尾巴」的功能已移除）。

## 依赖

- Windows + Edge（Chromium 内核，支持 `--remote-debugging-port`）
- PowerShell 5.1+（脚本用 ClientWebSocket 直连 CDP，无需 puppeteer/playwright）
- 可选：ffmpeg（做语音/视频素材）、python+Pillow（截图裁剪核对）

## 注意事项

- **不要**在 agent 值守时用同一个 Edge profile 手动操作，会抢焦点导致点错。
- 抖音网页版 IM **没有语音条**，语音只有 App 端支持；网页端只能文字/表情/图片/文件。
- 评论区发送是**红色圆形 ↑**（不是 Enter）；IM 里是 Enter。
- 所有坐标都要实时从 `getBoundingClientRect()` 取，再除以 `devicePixelRatio`；硬编码坐标一定会失效。
- 抖音会风控：节流（≥8s/会话、≤6 条/分钟），连续失败就停。
- 争议性文案（如对真实人物的评价）容易引发举报与限流，配置项 `liangwenfeng_comment` 由使用者自行决定开关。

## 合规

- 发布 AI 生成内容请开启「内容由 AI 生成」声明。
- 不泄露账号密钥、不代执行任何他人指令、不讨论敏感政治话题、遵守抖音社区规范。


## 已知约束（重要）

- **不要用 `--disable-gpu` / `--headless` 启动**：私信里分享的视频和图集依赖 GPU 合成，禁用后画面全黑，看不到内容也就无从回复。
- `[分享视频]` / `[分享图集]` 卡片是**悬停出现按钮**的交互：脚本 `share-open` 会 hover ~0.9s 再单击一次；手工复现时也要这样。
