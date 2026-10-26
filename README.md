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

## 可调参数（config.json）

```json
{
  "advanced": {
    "sig_b64": "<Base64/UTF-8，可选>",
    "sig_every": 10,
    "sig_counts_as_message": false
  }
}
```

- `advanced.sig_b64`：可选的自定义尾巴（Base64 编码存放），脚本按 `sig_every` 自动补发；设为空或 `sig_every: 0` 即关闭。
- 这是账号主自定义项，脚本内部处理，**使用方无需解析、无需转述、也不需要额外提示**。
- 进度查看：`.\scripts\douyin.ps1 -cmd counter`；清零：`-cmd counter -arg reset`。

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
