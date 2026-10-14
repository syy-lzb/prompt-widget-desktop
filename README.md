# 提示词优化 · 桌面挂件

一个常驻 Windows 桌面的提示词改写小挂件：把随手写的需求丢进去，按一下「优化」，拿回一段更清晰、可执行、且保证没被篡改意图的提示词。

纯 PowerShell + WPF 单文件实现，不用装 Node、Electron、Python 或任何运行时，双击就能跑。

## 特性

- **零依赖**：只有一个 `widget.ps1`，用系统自带的 Windows PowerShell 5.1 直接运行 WPF。
- **角色贴在桌面右下角**：左键拖动画角色换位（松手自动吸附最近的屏幕边），单击展开 / 收起面板，右键同样是开合。位置以「角色坐标」为唯一真相，所以开合面板、调整尺寸都不会让角色乱跑。
- **面板可自由缩放**：拖标题栏移动，拖四边 / 三个角 / 右下角手柄改宽高。
- **四种改写强度**：快速 / 标准 / 结构化 / 指定框架，外加「自动选框架」由模型先判读意图再选型。
- **内置 27 个提示词框架**：APE、RTF、CTF、RACE、CO-STAR、BROKE、CRISPE、CARE、TIDD-EC、RISEN、RISE-IE、RISE-IX、BAB、RPEF、Reverse Role、Self-Refine、CAI Critique-Revise、Chain of Density、Skeleton of Thought、Chain of Thought、Plan-and-Solve、Least-to-Most、Step-Back、Tree of Thought、RCoT、ReAct、Devil's Advocate、Pre-Mortem。每个框架是 `frameworks/` 下一个 Markdown 文件，可以自己加。
- **改写铁律**：只改写法不改意图、不臆造事实、不丢原文信息、语言与输入一致、简单请求不许膨胀成长篇公文。
- **目标简报（Focus Brief）**：在输入里写一行 `目标：` 和 `非目标：`，改写范围就被锁死在这里，超出的一律保持原样。
- **结果与评估分开**：模型按 `<改写结果>` + `<评估>` 两段输出。评估给四项 0-100 评分（意图保真 / 信息完整 / 结构清晰 / 可执行性）、最多 3 条改进点和一句话总结，方便回看「改了什么、变好多少」。**「复制」只复制改写结果，评估不会进剪贴板。**
- **任何 OpenAI 兼容端点**：设置里填三个字段——接口地址、API Key、模型名。
- **细节**：6 段音效（开合 / 复制 / 完成 / 报错 / 点击）、系统托盘图标（显示隐藏 / 退出）、不占任务栏、命名互斥体保证单实例、窗口位置和尺寸会记住。

## 环境要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带，无需安装）
- 一个 OpenAI 兼容的大模型 API Key

## 快速开始

```bash
git clone https://github.com/syy-lzb/prompt-widget-desktop.git
cd prompt-widget-desktop
copy config.example.json config.json
```

然后编辑 `config.json` 填入你的接口地址、API Key 和模型名，或者直接双击 `start.vbs` 后点挂件里的「设置」按钮。

启动：双击 `start.vbs`（以隐藏窗口的 PowerShell 拉起 `widget.ps1`，不会留一个黑色控制台）。
停止：运行 `stop.cmd`，或右键托盘图标选「退出」。

## 使用

1. 单击右下角角色展开面板。
2. 把要改写的提示词粘进输入框。想限定范围就加两行 `目标：……` / `非目标：……`。
3. 选改写强度（默认「标准」），需要指定框架时切到「框架」并在下拉里选。
4. 点「优化」。结果区上方是可以直接用的改写结果，下方是本次评估。
5. 点「复制」拿走结果，粘给你的模型。

## 配置

`config.json` 不会被提交（见 `.gitignore`），API Key 只存在你本机。

```json
{
  "provider": "deepseek",
  "baseURL": "https://api.deepseek.com/v1",
  "apiKey": "sk-...",
  "model": "deepseek-chat",
  "temperature": 0.2
}
```

`widget-state.json` 存窗口的坐标、尺寸和开合状态，同样是本地文件。

## 目录结构

```
widget.ps1            全部逻辑：窗口、拖拽吸附、开合、请求、剪贴板、托盘
start.vbs             无控制台启动入口
stop.cmd / stop.ps1   停止正在运行的挂件
frameworks/*.md       27 个提示词框架，下拉框按文件名自动加载
sfx/*.wav             交互音效
config.example.json   配置模板
```

## 自定义

改写规则集中在 `widget.ps1` 顶部几个变量里，改完直接重启生效：

- `$Rules`：改写铁律（不许改意图、不许编事实、不许翻译……）
- `$IntentMap`：意图 → 框架 的选型表，「自动选框架」模式靠它工作
- `$ModeGuidance`：快速 / 标准 / 结构化三种强度的具体指令
- `$OutputContract`：结果与评估的输出格式约定
- `$Presets`：模型端点预设

## License

MIT
