# 提示词优化小工具 —— 桌面独立挂件（WPF，无需任何运行时）
#
# 布局锚点规则（重要）：
#   角色永远贴在窗口的右下角，所以「角色的左上角坐标」$script:widgetX/$script:widgetY
#   是唯一的位置真相；窗口的 Left/Top 每次都由它反推，绝不反过来保存窗口坐标。
#   这样开合面板、切换尺寸、调整大小都不会让角色移动。
#
# 交互：
#   · 左键按住拖角色：移动，松手吸附到最近的屏幕边
#   · 左键单击角色（位移不到 $DRAG_SLOP 像素）：展开 / 收起（带音效）
#   · 右键点角色：同样开合，备用入口
#   · 面板标题栏左键拖动：移动窗口
#   · 拖拽面板四边 / 三个角 / 右下角手柄：自由调节窗口宽高
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Net.Http      # HttpClient 在 PS 5.1 里不会自动加载
Add-Type -AssemblyName System.Windows.Forms # 取鼠标物理坐标用于拖拽
Add-Type -AssemblyName System.Drawing       # 托盘图标

$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath    = Join-Path $ScriptDir 'config.json'
$StatePath     = Join-Path $ScriptDir 'widget-state.json'
$FrameworksDir = Join-Path $ScriptDir 'frameworks'
$SfxDir        = Join-Path $ScriptDir 'sfx'
$IconPath      = Join-Path $ScriptDir 'icon-192.png'

$WIDGET_W = 104; $WIDGET_H = 104
$MIN_W = 380; $MIN_H = 430
$MAX_W = 1400; $MAX_H = 1200
$DEFAULT_W = 470; $DEFAULT_H = 620
$EDGE = 20
$DRAG_SLOP = 6      # 左键位移不超过这个像素数就当作「点击」，否则当作「拖动」

# 单实例：命名互斥体比查进程可靠 —— 进程退出时系统自动释放
$script:singleInstance = New-Object System.Threading.Mutex($false, 'Local\PromptPolishTool')
if (-not $script:singleInstance.WaitOne(0)) { exit 0 }

# ── 音效 ────────────────────────────────────────────────────────────────

$script:sfx = @{}

function Play-Sfx([string]$name) {
  try {
    $path = Join-Path $SfxDir "$name.wav"
    if (-not (Test-Path $path)) { return }
    if (-not $script:sfx.ContainsKey($name)) {
      $script:sfx[$name] = New-Object System.Media.SoundPlayer $path
    }
    $script:sfx[$name].Play()
  } catch {
    # 没声音不该影响功能
  }
}

# ── 状态持久化 ──────────────────────────────────────────────────────────

function Load-UiState {
  try {
    if (Test-Path $StatePath) { return Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json }
  } catch { }
  return $null
}

$script:lastSave = [DateTime]::MinValue

function Save-UiState([bool]$force) {
  $now = Get-Date
  if (-not $force -and ($now - $script:lastSave).TotalMilliseconds -lt 400) { return }
  $script:lastSave = $now
  try {
    [ordered]@{
      widgetX  = [int]$script:widgetX
      widgetY  = [int]$script:widgetY
      panelW   = [int]$script:panelW
      panelH   = [int]$script:panelH
      charSize = [int]$WIDGET_W
      open     = [bool]$script:isOpen
    } | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
  } catch { }
}

# ── 依据 ────────────────────────────────────────────────────────────────

$Rules = @'
你是资深提示词工程师。你的工作是改写用户给出的提示词，让它更清晰、更可执行。

铁律：
1. 只改写法，不改意图。不新增用户没有提出的需求、字段、数据、技术选型或交付物。
2. 不臆造事实。用户没给的文件名、路径、版本号、库名、数值、接口，一律不要编。
3. 不丢信息。原文里的专有名词、路径、参数、约束、偏好、语气要求必须完整保留。
4. 消除歧义。把「优化一下」「弄好看点」「快点」这类不可判断的要求，落成可判断、可验收的说法；若仍无法确定用户想要什么，保留原话，不要替用户决定。
5. 补齐真正影响结果的结构：任务目标、背景与输入、输出要求（格式/长度/语言）、约束与边界、验收标准。缺什么补什么，不缺不补。
6. 长度服从复杂度。一句话的小请求不要膨胀成长篇公文；复杂任务才展开分点。
7. 语言与输入一致。输入中文输出中文，输入英文输出英文，不要翻译。
8. 只输出改写后的提示词本身。不要解释、不要开场白、不要用代码围栏包裹整段。
'@

$IntentMap = @'
判读意图后按下表选用框架（这是选型依据，不要跳过判读）：
- 从已有输出反推提示词 → RPEF
- 需求说不清、需要先问清 → Reverse Role Prompting
- 创作类：一次性极简 → APE；角色+任务 → RTF；情境+任务 → CTF；角色+情境+明确结果 → RACE；
  要多版本 → CRISPE；业务交付含指标 → BROKE；合规明确禁令 → CARE 或 TIDD-EC；
  受众语气关键 → CO-STAR；多步流程 → RISEN；输入到输出转换 → RISE-IE；需参考范例 → RISE-IX
- 改造已有内容：重写重构 → BAB；迭代提质 → Self-Refine；压缩提密 → Chain of Density；先骨架后展开 → Skeleton of Thought
- 推理计算：数值计算 → Plan-and-Solve；顺序多跳 → Least-to-Most；需第一性原理 → Step-Back；
  要多路径比较 → Tree of Thought；核查漏条件 → RCoT；线性分步 → Chain of Thought
- 挑错加固 → Self-Refine / CAI Critique-Revise / Devil's Advocate / Pre-Mortem / RCoT
- 工具调用迭代推理 → ReAct
'@

$ModeGuidance = @{
  quick      = '改写强度：快速。只修正歧义与明显缺失，保持原句结构与大致长度。'
  standard   = '改写强度：标准。在保持原意的前提下全面改写，重点补齐输出要求与验收标准。'
  structured = '改写强度：结构化。用简短标签行组织（任务、背景、输出要求、约束），没有内容的节不要保留。'
}

$ModeIds = @('quick', 'standard', 'structured', 'framework', 'auto')

# 输出契约：改写结果与评估分开，评估用于回看「改了什么、变好多少」
$OutputContract = @'
输出格式（严格遵守，两段都要有）：
<改写结果>
（改写后的提示词本身，可直接粘贴使用）
</改写结果>

<评估>
评分（每项 0-100 的整数）：
- 意图保真：<是否完整保留了原意与目标>
- 信息完整：<是否无遗漏、无臆造>
- 结构清晰：<组织是否易于理解与执行>
- 可执行性：<拿到即可执行、可验收>

改进点：
1. <最多 3 条，每条一句话，写清改了什么、为什么>
2. ...

总结：<一句话，说明本次优化最主要的提升>
</评估>
'@

$Presets = [ordered]@{
  deepseek  = @{ label = 'DeepSeek'; baseURL = 'https://api.deepseek.com/v1';                        models = @('deepseek-chat', 'deepseek-reasoner') }
  openai    = @{ label = 'OpenAI';   baseURL = 'https://api.openai.com/v1';                          models = @('gpt-4o-mini', 'gpt-4o') }
  moonshot  = @{ label = '月之暗面'; baseURL = 'https://api.moonshot.cn/v1';                        models = @('moonshot-v1-8k') }
  dashscope = @{ label = '阿里通义'; baseURL = 'https://dashscope.aliyuncs.com/compatible-mode/v1'; models = @('qwen-plus') }
  custom    = @{ label = '自定义';   baseURL = '';                                                  models = @() }
}

function Get-Config {
  $cfg = [ordered]@{
    provider = 'deepseek'; baseURL = 'https://api.deepseek.com/v1'; apiKey = ''
    model = 'deepseek-chat'; temperature = 0.2
  }
  if (Test-Path $ConfigPath) {
    try {
      $raw = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($k in @($cfg.Keys)) {
        if ($null -ne $raw.$k -and "$($raw.$k)" -ne '') { $cfg[$k] = $raw.$k }
      }
    } catch { }
  }
  return $cfg
}

function Save-Config($cfg) {
  $obj = [ordered]@{}
  foreach ($k in @($cfg.Keys)) { $obj[$k] = $cfg[$k] }
  ($obj | ConvertTo-Json) | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Get-Frameworks {
  if (-not (Test-Path $FrameworksDir)) { return @() }
  $special = @{ react = 'ReAct'; rcot = 'RCoT'; rpef = 'RPEF'; 'tdd-ec' = 'TDD-EC' }
  $list = @()
  foreach ($file in (Get-ChildItem $FrameworksDir -Filter *.md | Sort-Object Name)) {
    $id = $file.BaseName
    if ($special.ContainsKey($id)) { $label = $special[$id] }
    else { $label = (($id -split '[-_]') | ForEach-Object { $_.ToUpper() }) -join '-' }
    $list += [pscustomobject]@{ Id = $id; Label = $label }
  }
  return $list
}

function Build-SystemPrompt([string]$mode, [string]$frameworkId, [string]$brief) {
  $parts = @($Rules)
  $cites = @('改写铁律')
  if ($mode -eq 'auto') {
    $parts += $IntentMap
    $parts += '先判定意图并选定框架，然后按该框架的结构改写。不要输出判读过程，只输出改写结果。'
    $cites += 'prompt-architect 意图分类表'
  } elseif ($mode -eq 'framework' -and $frameworkId) {
    $docPath = Join-Path $FrameworksDir "$frameworkId.md"
    if (Test-Path $docPath) {
      $doc = Get-Content $docPath -Raw -Encoding UTF8
      $parts += "按以下框架改写，严格遵守它的结构要求：`n`n<框架文档>`n$doc`n</框架文档>"
      $cites += "prompt-architect · $frameworkId"
    } else {
      $parts += $ModeGuidance['standard']
    }
  } else {
    if ($ModeGuidance.ContainsKey($mode)) { $parts += $ModeGuidance[$mode] }
    else { $parts += $ModeGuidance['standard'] }
    if ($mode -eq 'structured') { $cites += '结构化改写' }
    elseif ($mode -eq 'quick') { $cites += '最小干预' }
    else { $cites += '标准改写' }
  }
  # 目标简报（Focus Brief）：输入里声明的目标与非目标，是本次改写的唯一范围
  if ($brief) {
    $parts += "目标简报：`n$brief`n`n改写必须严格围绕上述目标，不新增目标之外的需求、字段、数据或交付物；非目标范围内的一律保持原样。"
    $cites += '目标简报'
  }
  $parts += $OutputContract
  return @{ System = ($parts -join "`n`n"); Cites = $cites }
}

# 边等 HTTP 响应边让 WPF 处理消息队列，否则界面和转圈会一起冻住。
# 用 Background 优先级：比它高的（输入、渲染、绑定）都会被处理，动画照转。
function Send-AndPump([System.Net.Http.HttpClient]$client, [System.Net.Http.HttpRequestMessage]$req) {
  $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
  $noop = [System.Action] { [void]0 }
  function Wait-Task($t) {
    while (-not $t.IsCompleted) {
      $dispatcher.Invoke($noop, [System.Windows.Threading.DispatcherPriority]::Background)
      Start-Sleep -Milliseconds 20
    }
  }
  $task = $client.SendAsync($req)
  Wait-Task $task
  $resp = $task.GetAwaiter().GetResult()
  try {
    $read = $resp.Content.ReadAsByteArrayAsync()
    Wait-Task $read
    $bytes = $read.GetAwaiter().GetResult()
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    if (-not $resp.IsSuccessStatusCode) {
      $head = $json
      if ($head.Length -gt 200) { $head = $head.Substring(0, 200) }
      throw "接口返回 $([int]$resp.StatusCode)：$head"
    }
    return $json
  } finally {
    $resp.Dispose()
  }
}

function Invoke-Optimize([string]$text, [string]$mode, [string]$frameworkId, [string]$brief) {
  $cfg = Get-Config
  if (-not $cfg.apiKey) { throw '还没有配 API Key，点「设置」填一下' }
  $built = Build-SystemPrompt $mode $frameworkId $brief

  $payload = [ordered]@{
    model       = $cfg.model
    temperature = [double]$cfg.temperature
    messages    = @(
      [ordered]@{ role = 'system'; content = $built.System }
      [ordered]@{ role = 'user';   content = $text }
    )
  }
  $body = $payload | ConvertTo-Json -Depth 6 -Compress

  $base = "$($cfg.baseURL)".TrimEnd('/')

  # 不用 Invoke-RestMethod：PowerShell 5.1 在响应头没有 charset 时（这里用的端点
  # 返回的就是 application/json）会按 ISO-8859-1 解码响应体，中文全变「æµ‹è¯•」
  # 这种乱码。改成自己取字节、按 UTF-8 解，顺带让等待过程可以推进界面。
  $client = New-Object System.Net.Http.HttpClient
  $client.Timeout = [TimeSpan]::FromSeconds(120)
  try {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$base/chat/completions")
    $req.Content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', "$($cfg.apiKey)")
    $json = Send-AndPump $client $req
  } finally {
    $client.Dispose()
  }
  $resp = $json | ConvertFrom-Json
  $answer = $resp.choices[0].message.content
  if (-not $answer) { throw '模型没有返回内容，重试一次看看' }

  $trimmed = "$answer".Trim()
  $m = [regex]::Match($trimmed, '^```[a-zA-Z0-9_+-]*\r?\n([\s\S]*?)\r?\n```$')
  if ($m.Success) { $trimmed = $m.Groups[1].Value.Trim() }
  return @{ Text = $trimmed; Cites = $built.Cites }
}

# ── 界面 ────────────────────────────────────────────────────────────────

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="提示词优化" Width="470" Height="620"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="True"
        WindowStartupLocation="Manual" FontFamily="Microsoft YaHei UI" FontSize="13">
  <Grid>
    <Border x:Name="Panel" CornerRadius="16" Background="#FAF9F5" BorderBrush="#E6E3DA" BorderThickness="1"
            Margin="0,0,0,104" Visibility="Collapsed">
      <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="5" Direction="270" Opacity="0.22" Color="#000000"/></Border.Effect>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Border x:Name="HeadBar" Grid.Row="0" BorderBrush="#E6E3DA" BorderThickness="0,0,0,1" Padding="13,9,8,9" Background="Transparent">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="提示词优化" FontWeight="SemiBold" Foreground="#1F1E1D" VerticalAlignment="Center"/>
            <TextBlock x:Name="CitesText" Text="" Foreground="#9A9791" FontSize="10.5" Margin="8,0,0,0"
                       VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Border>

        <Grid Grid.Row="1" Margin="13,12,13,13">
          <Grid.RowDefinitions>
            <RowDefinition Height="2*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="2.2*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <Border Grid.Row="0" Background="White" BorderBrush="#E6E3DA" BorderThickness="1" CornerRadius="12">
            <DockPanel Margin="11,8,11,10">
              <TextBlock DockPanel.Dock="Top" Text="你的提示词" FontSize="10.5" FontWeight="SemiBold" Foreground="#6B6B68" Margin="0,0,0,4"/>
              <TextBox x:Name="InputBox" AcceptsReturn="True" TextWrapping="Wrap" BorderThickness="0"
                       Background="Transparent" VerticalScrollBarVisibility="Auto" Foreground="#1F1E1D"
                       SelectionBrush="#D97757" VerticalContentAlignment="Top"/>
            </DockPanel>
          </Border>

          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,9,0,9">
            <ComboBox x:Name="ModeBox" Width="120" SelectedIndex="1"/>
            <ComboBox x:Name="FrameworkBox" Width="150" Margin="7,0,0,0" IsEnabled="False"/>
            <Button x:Name="GearBtn" Content="设置" Width="52" Height="30" Margin="7,0,0,0" Cursor="Hand"
                    Background="#F4F2EC" Foreground="#6B6B68" BorderThickness="0"/>
          </StackPanel>

          <Border Grid.Row="2" Background="White" BorderBrush="#E6E3DA" BorderThickness="1" CornerRadius="12">
            <DockPanel Margin="11,8,11,10">
              <TextBlock DockPanel.Dock="Top" Text="优化结果（可直接改）" FontSize="10.5" FontWeight="SemiBold" Foreground="#6B6B68" Margin="0,0,0,4"/>
              <TextBox x:Name="OutputBox" AcceptsReturn="True" TextWrapping="Wrap" BorderThickness="0"
                       Background="Transparent" VerticalScrollBarVisibility="Auto" Foreground="#1F1E1D"
                       SelectionBrush="#D97757" VerticalContentAlignment="Top"/>
            </DockPanel>
          </Border>

          <Grid Grid.Row="3" Margin="0,10,18,0">
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
              <Ellipse x:Name="Spinner" Width="13" Height="13" Stroke="#D97757" StrokeThickness="2"
                       StrokeDashArray="3 4.5" Visibility="Collapsed" Margin="0,0,7,0"
                       RenderTransformOrigin="0.5,0.5">
                <Ellipse.RenderTransform>
                  <RotateTransform x:Name="SpinnerRotate"/>
                </Ellipse.RenderTransform>
              </Ellipse>
              <TextBlock x:Name="StatusText" Text="" Foreground="#C2410C" FontSize="11" VerticalAlignment="Center"
                         TextTrimming="CharacterEllipsis" MaxWidth="200"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="ClearBtn" Content="清空" Padding="12,7" Cursor="Hand"
                      Background="#F4F2EC" Foreground="#6B6B68" BorderThickness="0"/>
              <Button x:Name="CopyBtn" Content="复制" Padding="12,7" Margin="6,0,0,0" Cursor="Hand" IsEnabled="False"
                      Background="#F4F2EC" Foreground="#6B6B68" BorderThickness="0"/>
              <Button x:Name="GoBtn" Content="优化" Padding="16,7" Margin="6,0,0,0" Cursor="Hand"
                      Background="#D97757" Foreground="White" BorderThickness="0" FontWeight="SemiBold"/>
            </StackPanel>
          </Grid>
        </Grid>
      </Grid>
    </Border>

    <!-- 尺寸拖拽层：四边 + 三个角；右下角与角色重叠，由 ResizeGrip 手柄承担 -->
    <Grid x:Name="ResizeLayer" Visibility="Collapsed">
      <Border x:Name="RzLeft"   Width="7"   HorizontalAlignment="Left"   VerticalAlignment="Stretch" Background="Transparent" Cursor="SizeWE"/>
      <Border x:Name="RzRight"  Width="7"   HorizontalAlignment="Right"  VerticalAlignment="Stretch" Margin="0,0,0,104" Background="Transparent" Cursor="SizeWE"/>
      <Border x:Name="RzTop"    Height="7"  HorizontalAlignment="Stretch" VerticalAlignment="Top"    Background="Transparent" Cursor="SizeNS"/>
      <Border x:Name="RzBottom" Height="7"  HorizontalAlignment="Stretch" VerticalAlignment="Bottom" Margin="0,0,104,0" Background="Transparent" Cursor="SizeNS"/>
      <Border x:Name="RzTL"     Width="14"  Height="14" HorizontalAlignment="Left"   VerticalAlignment="Top"    Background="Transparent" Cursor="SizeNWSE"/>
      <Border x:Name="RzTR"     Width="14"  Height="14" HorizontalAlignment="Right"  VerticalAlignment="Top"    Background="Transparent" Cursor="SizeNESW"/>
      <Border x:Name="RzBL"     Width="14"  Height="14" HorizontalAlignment="Left"   VerticalAlignment="Bottom" Background="Transparent" Cursor="SizeNESW"/>
      <Border x:Name="ResizeGrip" Width="22" Height="22" HorizontalAlignment="Right" VerticalAlignment="Bottom"
              Background="Transparent" Cursor="SizeNWSE" Margin="0,0,4,108" ToolTip="拖动调整窗口大小">
        <Path Data="M 13,2 L 2,13 M 17,6 L 6,17 M 20,11 L 11,20" Stroke="#C9C6BD" StrokeThickness="1.6"
              StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
      </Border>
    </Grid>

    <Border x:Name="Character" Width="104" Height="104" CornerRadius="52" Cursor="Hand"
            HorizontalAlignment="Right" VerticalAlignment="Bottom" Background="#EEF1F8"
            ToolTip="左键：展开 / 收起&#x0a;左键按住拖动：移动">
      <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="3" Direction="270" Opacity="0.28" Color="#000000"/></Border.Effect>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$script:charFlip = $null
if (Test-Path $IconPath) {
  $brush = New-Object System.Windows.Media.ImageBrush
  $brush.ImageSource = [System.Windows.Media.Imaging.BitmapImage]::new((New-Object Uri $IconPath))
  $brush.Stretch = 'UniformToFill'
  $window.FindName('Character').Background = $brush
  # 角色左右镜像：翻转整个角色元素，用 RenderTransform 最可靠
  $flip = New-Object System.Windows.Media.ScaleTransform
  $flip.ScaleX = 1
  $character = $window.FindName('Character')
  $character.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
  $character.RenderTransform = $flip
  $script:charFlip = $flip
}

$panel     = $window.FindName('Panel')
$character = $window.FindName('Character')
$grip      = $window.FindName('ResizeGrip')
$resizeLayer = $window.FindName('ResizeLayer')
$inputBox  = $window.FindName('InputBox')
$outputBox = $window.FindName('OutputBox')
$status    = $window.FindName('StatusText')
$cites     = $window.FindName('CitesText')
$goBtn     = $window.FindName('GoBtn')
$copyBtn   = $window.FindName('CopyBtn')
$clearBtn  = $window.FindName('ClearBtn')
$modeBox   = $window.FindName('ModeBox')
$fwBox     = $window.FindName('FrameworkBox')
$spinner   = $window.FindName('Spinner')
$spinRot   = $window.FindName('SpinnerRotate')

# ── 锚点状态：角色左上角坐标 + 面板尺寸 ──────────────────────────────────

$work = [System.Windows.SystemParameters]::WorkArea
$savedState = Load-UiState

$script:panelW = $DEFAULT_W
$script:panelH = $DEFAULT_H
$script:widgetX = $work.Right - $WIDGET_W - 26
$script:widgetY = $work.Bottom - $WIDGET_H - 26

if ($null -ne $savedState) {
  try {
    if ($savedState.panelW -ge $MIN_W -and $savedState.panelW -le $MAX_W) { $script:panelW = [double]$savedState.panelW }
    if ($savedState.panelH -ge $MIN_H -and $savedState.panelH -le $MAX_H) { $script:panelH = [double]$savedState.panelH }
    if ($null -ne $savedState.widgetX) { $script:widgetX = [double]$savedState.widgetX }
    if ($null -ne $savedState.widgetY) { $script:widgetY = [double]$savedState.widgetY }
    if ($null -ne $savedState.charSize) {
      $cs = [double]$savedState.charSize
      if ($cs -ge 64 -and $cs -le 200) {
        $script:WIDGET_W = $cs
        $script:WIDGET_H = $cs
      }
    }
  } catch { }
}

# 应用恢复的角色尺寸
$character.Width = $WIDGET_W
$character.Height = $WIDGET_H
$character.CornerRadius = New-Object System.Windows.CornerRadius($WIDGET_W / 2)

function Clamp-Widget {
  # 允许角色部分超出屏幕（只保证中心在屏内），面板可见性由边缘自适应保证
  $halfW = $WIDGET_W / 2
  $halfH = $WIDGET_H / 2
  if ($script:widgetX -lt $work.Left - $halfW) { $script:widgetX = $work.Left - $halfW }
  if ($script:widgetY -lt $work.Top - $halfH) { $script:widgetY = $work.Top - $halfH }
  if ($script:widgetX -gt $work.Right - $halfW) { $script:widgetX = $work.Right - $halfW }
  if ($script:widgetY -gt $work.Bottom - $halfH) { $script:widgetY = $work.Bottom - $halfH }
}

Clamp-Widget

$script:isOpen = $false

# 判断角色在屏幕左半还是右半（不依赖 HorizontalAlignment，避免循环依赖）
function Get-CharSide {
  $screenMid = ($work.Left + $work.Right) / 2
  $centerX = $script:widgetX + $WIDGET_W / 2
  if ($centerX -lt $screenMid) { return 'Left' }
  return 'Right'
}

# 角色面向屏幕中心：靠屏幕左翻转（面朝右），靠屏幕右保持原图（面朝左）
# 面板跟随角色朝向：面朝右时角色在窗口左下角，面朝左时在右下角
function Update-CharFlip {
  $isLeft = (Get-CharSide) -eq 'Left'
  if ($null -ne $script:charFlip) {
    $script:charFlip.ScaleX = if ($isLeft) { -1.0 } else { 1.0 }
  }
  $character.HorizontalAlignment = if ($isLeft) { 'Left' } else { 'Right' }
}

# 唯一的布局出口：由「角色坐标 + 面板尺寸 + 开合状态」推窗口的位置与大小。
# 角色贴在窗口下角（左下或右下跟随朝向），窗口左上角由角色坐标反推。
function Apply-Layout {
  if ($script:isOpen) {
    $window.Width = $script:panelW
    $window.Height = $script:panelH
  } else {
    $window.Width = $WIDGET_W
    $window.Height = $WIDGET_H
  }
  # 展开时若面板会顶出屏幕边缘，就把角色往里让一点，保证面板完整可见
  if ($script:isOpen) {
    $spanX = $window.Width - $WIDGET_W
    $spanY = $window.Height - $WIDGET_H
    # 面板方向跟随角色位置：角色在左下角时面板在右，在右下角时面板在左
    if ((Get-CharSide) -eq 'Left') {
      if (($script:widgetX + $spanX) -gt $work.Right) { $script:widgetX = $work.Right - $spanX }
    } else {
      if (($script:widgetX - $spanX) -lt $work.Left) { $script:widgetX = $work.Left + $spanX }
    }
    if (($script:widgetY - $spanY) -lt $work.Top) { $script:widgetY = $work.Top + $spanY }
  }
  Clamp-Widget
  $panel.Visibility = 'Visible'
  if (-not $script:isOpen) { $panel.Visibility = 'Collapsed' }
  $resizeLayer.Visibility = $panel.Visibility
  # 先更新角色朝向与位置，再算窗口左上角
  Update-CharFlip
  if ($character.HorizontalAlignment -eq 'Left') {
    $window.Left = $script:widgetX
  } else {
    $window.Left = $script:widgetX - ($window.Width - $WIDGET_W)
  }
  $window.Top  = $script:widgetY - ($window.Height - $WIDGET_H)
}

# 由窗口当前位置反推角色坐标（拖动之后用）
function Sync-WidgetFromWindow {
  if ($character.HorizontalAlignment -eq 'Left') {
    $script:widgetX = $window.Left
  } else {
    $script:widgetX = $window.Left + ($window.Width - $WIDGET_W)
  }
  $script:widgetY = $window.Top + ($window.Height - $WIDGET_H)
  Clamp-Widget
}

function Set-Open([bool]$open) {
  if ($script:isOpen -eq $open) { return }
  $script:isOpen = $open
  Apply-Layout
  if ($open) { Play-Sfx 'open' } else { Play-Sfx 'close' }
  Save-UiState $true
}

# 首次布局：恢复上次的开合状态，位置与尺寸都来自保存值
if ($null -ne $savedState -and $savedState.open -eq $true) { $script:isOpen = $true }
Apply-Layout

# ── 下拉内容 ────────────────────────────────────────────────────────────

foreach ($m in @('快速', '标准', '结构化', '框架', '自动选框架')) {
  $item = New-Object System.Windows.Controls.ComboBoxItem
  $item.Content = $m
  $modeBox.Items.Add($item) | Out-Null
}
$modeBox.SelectedIndex = 1

foreach ($f in (Get-Frameworks)) {
  $item = New-Object System.Windows.Controls.ComboBoxItem
  $item.Content = $f.Label
  $item.Tag = $f.Id
  $fwBox.Items.Add($item) | Out-Null
}
if ($fwBox.Items.Count -gt 0) { $fwBox.SelectedIndex = 0 }

# ── 角色：左键拖动 + 左键单击开合；右键开合 ───────────────────────────────
# 一个键干两件事，靠位移阈值区分：按下后位移超过 $DRAG_SLOP 就锁定为「拖动」，
# 之后的 MouseMove 才真正搬窗口；松手时若始终没超过阈值，就当成一次「点击」切换开合。
# 这样左键既能拖又能点，不需要依赖 $window.DragMove()（那个只认左键、且在
# 面板收起时窗口尺寸为角色尺寸，行为不一致）。

$script:drag = $null

$character.Add_MouseLeftButtonDown({
  param($s, $e)
  $p = $e.GetPosition($window)
  $script:drag = @{ X = $p.X; Y = $p.Y; Moved = $false }
  try { $character.CaptureMouse() } catch { }
  $e.Handled = $true
})

$character.Add_MouseMove({
  param($s, $e)
  if ($null -eq $script:drag) { return }
  $p = $e.GetPosition($window)
  $dx = $p.X - $script:drag.X
  $dy = $p.Y - $script:drag.Y
  if (-not $script:drag.Moved) {
    if (([Math]::Abs($dx) -le $DRAG_SLOP) -and ([Math]::Abs($dy) -le $DRAG_SLOP)) { return }
    $script:drag.Moved = $true
  }
  # 参考点 X0/Y0 只取一次，全程不刷新。因为 p.X = 鼠标屏幕X - 窗口Left，
  # 同一帧内两项同源、滞后互相抵消，于是 Left += (p.X - X0) 的累计结果恒等于
  # (鼠标屏幕X - X0)，与中途丢帧、消息合并、渲染滞后全都无关 —— 拖到哪就是哪。
  $window.Left = $window.Left + $dx
  $window.Top  = $window.Top + $dy
})

$character.Add_MouseLeftButtonUp({
  param($s, $e)
  if ($null -eq $script:drag) { return }
  $moved = $script:drag.Moved
  $script:drag = $null
  try { $character.ReleaseMouseCapture() } catch { }

  if (-not $moved) {
    Set-Open (-not $script:isOpen)     # 只是一次点击
    return
  }

  Sync-WidgetFromWindow
  # 吸附到最近的屏幕边
  if ($script:widgetX -lt $work.Left + 60) { $script:widgetX = $work.Left + $EDGE }
  elseif (($work.Right - $script:widgetX - $WIDGET_W) -lt 60) { $script:widgetX = $work.Right - $WIDGET_W - $EDGE }
  if ($script:widgetY -lt $work.Top + 60) { $script:widgetY = $work.Top + $EDGE }
  elseif (($work.Bottom - $script:widgetY - $WIDGET_H) -lt 60) { $script:widgetY = $work.Bottom - $WIDGET_H - $EDGE }
  Apply-Layout
  Save-UiState $true
})

# 右键点角色：直接开合（不经过拖动判定，所以永远不误判）
$character.Add_MouseRightButtonDown({
  param($s, $e)
  $script:drag = $null
  Set-Open (-not $script:isOpen)
  $e.Handled = $true
})

# 兜底：捕获被抢走（切窗口、锁屏）时清掉拖动状态，免得下次移动鼠标就跟着窗口跑
$character.Add_LostMouseCapture({
  param($s, $e)
  $script:drag = $null
})

# 滚轮调节头像大小（范围 64-200）
$character.Add_MouseWheel({
  param($s, $e)
  $delta = if ($e.Delta -gt 0) { 10 } else { -10 }
  $newSize = $WIDGET_W + $delta
  if ($newSize -lt 64) { $newSize = 64 }
  if ($newSize -gt 200) { $newSize = 200 }
  $script:WIDGET_W = $newSize
  $script:WIDGET_H = $newSize
  $character.Width = $newSize
  $character.Height = $newSize
  $character.CornerRadius = New-Object System.Windows.CornerRadius($newSize / 2)
  Apply-Layout
  Save-UiState $true
  $e.Handled = $true
})

# ── 面板标题栏：左键拖动窗口（这里用 DragMove 是安全的） ──────────────────

$window.FindName('HeadBar').Add_MouseLeftButtonDown({
  param($s, $e)
  if ($e.LeftButton -ne 'Pressed') { return }
  try {
    $window.DragMove()
    Sync-WidgetFromWindow
    Apply-Layout
    Save-UiState $true
  } catch { }
})

# ── 尺寸拖拽：四边 + 三个角 + 右下角手柄 ─────────────────────────────────
# 全部走同一套逻辑：记录鼠标屏幕坐标与初始宽高，移动时按边/角更新 panelW/panelH。
# 位置仍然由 Apply-Layout 从角色坐标反推，所以角色永远不动。
# 用屏幕坐标而不是 $e.GetPosition($window)：拖左/上边缘时窗口左上角本身在动，
# 窗口相对坐标会失准（宽高只走一半速度），屏幕坐标是绝对的，落点精确。

$script:resizing = $null

function Start-Resize($e, [string]$edges) {
  # 用鼠标物理坐标做参考点：窗口位置本身在拖拽中变化，窗口相对坐标会失准
  $cur = [System.Windows.Forms.Cursor]::Position
  $script:resizing = @{ SX = $cur.X; SY = $cur.Y; W = $script:panelW; H = $script:panelH; Edges = $edges }
  $e.Handled = $true
}

function Move-Resize($e) {
  if ($null -eq $script:resizing) { return }
  # Cursor.Position 返回物理像素，而 panelW/panelH 是 WPF 的逻辑 DIP，需要除以缩放比
  $cur = [System.Windows.Forms.Cursor]::Position
  $scale = [System.Windows.Media.VisualTreeHelper]::GetDpi($window).DpiScaleX
  if ($scale -le 0) { $scale = 1 }
  $dx = ($cur.X - $script:resizing.SX) / $scale
  $dy = ($cur.Y - $script:resizing.SY) / $scale
  $w = $script:resizing.W
  $h = $script:resizing.H
  if ($script:resizing.Edges -match 'L') { $w = $script:resizing.W - $dx }
  if ($script:resizing.Edges -match 'R') { $w = $script:resizing.W + $dx }
  if ($script:resizing.Edges -match 'T') { $h = $script:resizing.H - $dy }
  if ($script:resizing.Edges -match 'B') { $h = $script:resizing.H + $dy }
  if ($w -lt $MIN_W) { $w = $MIN_W }
  if ($h -lt $MIN_H) { $h = $MIN_H }
  if ($w -gt $MAX_W) { $w = $MAX_W }
  if ($h -gt $MAX_H) { $h = $MAX_H }
  $script:panelW = $w
  $script:panelH = $h
  Apply-Layout
}

function End-Resize {
  if ($null -eq $script:resizing) { return }
  $script:resizing = $null
  Play-Sfx 'tap'
  Save-UiState $true
}

# 边缘条 + 三个角 + 右下角手柄（RB）。Tag 存边角标记，避免闭包变量捕获问题。
$resizeTargets = @(
  @{ name = 'RzLeft';     edges = 'L'  },
  @{ name = 'RzRight';    edges = 'R'  },
  @{ name = 'RzTop';      edges = 'T'  },
  @{ name = 'RzBottom';   edges = 'B'  },
  @{ name = 'RzTL';       edges = 'LT' },
  @{ name = 'RzTR';       edges = 'RT' },
  @{ name = 'RzBL';       edges = 'LB' },
  @{ name = 'ResizeGrip'; edges = 'RB' }
)

foreach ($t in $resizeTargets) {
  $el = $window.FindName($t.name)
  $el.Tag = $t.edges
  $el.Add_MouseLeftButtonDown({
    param($s, $e)
    $s.CaptureMouse()
    Start-Resize $e "$($s.Tag)"
  })
  $el.Add_MouseMove({
    param($s, $e)
    Move-Resize $e
  })
  $el.Add_MouseLeftButtonUp({
    param($s, $e)
    try { $s.ReleaseMouseCapture() } catch { }
    End-Resize
    $e.Handled = $true
  })
}

# ── 尺寸控制 ────────────────────────────────────────────────────────────
# 改为拖拽四边 / 角点 / 右下角手柄自由调节（见 Start-Resize / Move-Resize / End-Resize），
# 不再使用固定档位切换，也不再有档位控件。

# ── 运行中指示 ──────────────────────────────────────────────────────────

$script:spinAnim = New-Object System.Windows.Media.Animation.DoubleAnimation
$script:spinAnim.From = 0
$script:spinAnim.To = 360
$script:spinAnim.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(850))
$script:spinAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever

function Set-Busy([bool]$busy) {
  if ($busy) {
    $spinner.Visibility = 'Visible'
    $spinRot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $script:spinAnim)
  } else {
    $spinRot.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    $spinRot.Angle = 0
    $spinner.Visibility = 'Collapsed'
  }
}

# ── 优化 ────────────────────────────────────────────────────────────────

function Invoke-OptimizeFlow {
  $text = $inputBox.Text
  $status.Text = ''
  $status.Foreground = '#C2410C'
  if ([string]::IsNullOrWhiteSpace($text)) {
    $status.Text = '先写点东西'
    Play-Sfx 'error'
    return
  }

  $goBtn.IsEnabled = $false
  $goBtn.Content = '优化中…'
  $copyBtn.IsEnabled = $false
  $outputBox.Text = ''
  Set-Busy $true

  $mode = $ModeIds[$modeBox.SelectedIndex]
  $fw = ''
  if ($null -ne $fwBox.SelectedItem) { $fw = $fwBox.SelectedItem.Tag }

  # 目标简报（Focus Brief）：输入里「目标：」「非目标：」两行，作为改写的唯一范围
  $briefParts = @()
  $mg = [regex]::Match($text, '(?m)^目标[:：]\s*(.+)$')
  if ($mg.Success) { $briefParts += "目标：$($mg.Groups[1].Value.Trim())" }
  $mn = [regex]::Match($text, '(?m)^非目标[:：]\s*(.+)$')
  if ($mn.Success) { $briefParts += "非目标：$($mn.Groups[1].Value.Trim())" }
  $brief = $briefParts -join "`n"

  try {
    $result = Invoke-Optimize $text $mode $fw $brief
    # 分离「改写结果」与「评估」两段；模型没按格式输出时整体显示，保证结果可用
    $rewrite = $result.Text
    $review = ''
    $mr = [regex]::Match($result.Text, '(?s)<改写结果>(.*?)</改写结果>')
    $mv = [regex]::Match($result.Text, '(?s)<评估>(.*?)</评估>')
    if ($mr.Success) { $rewrite = $mr.Groups[1].Value.Trim() }
    if ($mv.Success) { $review = $mv.Groups[1].Value.Trim() }
    $script:lastRewrite = $rewrite
    if ($review) {
      $outputBox.Text = $rewrite + "`r`n`r`n――――――――――`r`n`r`n" + $review
    } else {
      $outputBox.Text = $rewrite
    }
    $copyBtn.IsEnabled = $true
    $cites.Text = '依据：' + ($result.Cites -join ' · ')
    $status.Foreground = '#3F7D5A'
    $status.Text = "$($text.Length) → $($rewrite.Length) 字"
    Play-Sfx 'done'
  } catch {
    $status.Foreground = '#C2410C'
    $status.Text = $_.Exception.Message
    Play-Sfx 'error'
  } finally {
    Set-Busy $false
    $goBtn.IsEnabled = $true
    $goBtn.Content = '优化'
  }
}

$clearBtn.Add_Click({
  $inputBox.Text = ''
  $outputBox.Text = ''
  $script:lastRewrite = ''
  $cites.Text = ''
  $copyBtn.IsEnabled = $false
  $status.Foreground = '#6B6B68'
  $status.Text = '已清空'
  Play-Sfx 'tap'
  $inputBox.Focus() | Out-Null
})

$goBtn.Add_Click({ Invoke-OptimizeFlow })

$copyBtn.Add_Click({
  # 只复制改写结果本身，评估段仅供回看，不进剪贴板
  $toCopy = $script:lastRewrite
  if (-not $toCopy) { $toCopy = $outputBox.Text }
  if ($toCopy) {
    [System.Windows.Clipboard]::SetText($toCopy)
    $status.Foreground = '#3F7D5A'
    $status.Text = '已复制'
    Play-Sfx 'copy'
  }
})

$modeBox.Add_SelectionChanged({
  param($s, $e)
  if ($null -ne $fwBox) {
    $fwBox.IsEnabled = ($modeBox.SelectedIndex -eq 3)
    Play-Sfx 'tap'
  }
})

$window.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq 'Escape' -and $script:isOpen) { Set-Open $false }
  if ($e.Key -eq 'Enter' -and ($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
    Invoke-OptimizeFlow
  }
})

# ── 设置 ────────────────────────────────────────────────────────────────

$window.FindName('GearBtn').Add_Click({
  Play-Sfx 'tap'
  $cfg = Get-Config
  $dlg = New-Object System.Windows.Window
  $dlg.Title = '模型配置'
  $dlg.Width = 440; $dlg.Height = 372
  $dlg.WindowStartupLocation = 'CenterOwner'
  $dlg.ResizeMode = 'NoResize'
  $dlg.FontFamily = 'Microsoft YaHei UI'
  $dlg.FontSize = 13
  $dlg.Owner = $window

  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Margin = '20'

  function Add-Field($title, $control) {
    $l = New-Object System.Windows.Controls.TextBlock
    $l.Text = $title; $l.Foreground = '#6B6B68'; $l.FontSize = 11
    $sp.Children.Add($l) | Out-Null
    $control.Padding = '6,5,6,5'
    $control.Margin = '0,3,0,12'
    $sp.Children.Add($control) | Out-Null
  }

  $t1 = New-Object System.Windows.Controls.TextBox; $t1.Text = "$($cfg.baseURL)"
  Add-Field '接口地址（任何 OpenAI 兼容端点）' $t1
  $t2 = New-Object System.Windows.Controls.PasswordBox; $t2.Password = "$($cfg.apiKey)"
  Add-Field 'API Key' $t2
  $t3 = New-Object System.Windows.Controls.TextBox; $t3.Text = "$($cfg.model)"
  Add-Field '模型名' $t3

  $btn = New-Object System.Windows.Controls.Button
  $btn.Content = '保存'; $btn.Padding = '18,7'
  $btn.HorizontalAlignment = 'Right'
  $btn.Background = '#D97757'; $btn.Foreground = 'White'; $btn.BorderThickness = 0
  $btn.Add_Click({
    $c = Get-Config
    $c.baseURL = $t1.Text.Trim()
    if ($t2.Password.Trim() -ne '') { $c.apiKey = $t2.Password.Trim() }
    $c.model = $t3.Text.Trim()
    Save-Config $c
    Play-Sfx 'done'
    $dlg.Close()
  })
  $sp.Children.Add($btn) | Out-Null

  $dlg.Content = $sp
  $dlg.ShowDialog() | Out-Null
})

# ── 隐藏任务栏按钮 ──────────────────────────────────────────────────────
# 用 WS_EX_TOOLWINDOW 扩展样式：ShowInTaskbar=False 在 AllowsTransparency=True
# 下会让窗口不渲染，所以改用样式位来隐藏任务栏按钮。
Add-Type -Namespace WidTool -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
'@

# ── 系统托盘图标 ────────────────────────────────────────────────────────
# 任务栏不占位，改用托盘图标控制显示/隐藏与退出

$iconIcoPath = Join-Path $ScriptDir 'icon.ico'
$script:tray = $null
if (Test-Path $iconIcoPath) {
  $script:tray = New-Object System.Windows.Forms.NotifyIcon
  $script:tray.Icon = New-Object System.Drawing.Icon($iconIcoPath)
  $script:tray.Text = '提示词优化'
  $script:tray.Visible = $true

  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miToggle = $menu.Items.Add('显示 / 隐藏')
  $miExit   = $menu.Items.Add('退出')
  $script:tray.ContextMenuStrip = $menu

  $miToggle.Add_Click({
    if ($window.IsVisible) {
      $window.Hide()
    } else {
      $window.Show()
      $window.Activate()
    }
  })
  $miExit.Add_Click({
    $script:tray.Visible = $false
    $script:tray.Dispose()
    $window.Close()
  })
  $script:tray.Add_Click({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $window.Show()
      $window.Activate()
    }
  })
}

$window.Add_Closed({
  Save-UiState $true
  if ($null -ne $script:tray) {
    $script:tray.Visible = $false
    $script:tray.Dispose()
    $script:tray = $null
  }
  # 停掉 Dispatcher.Run() 的消息循环，脚本才能正常退出
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

# 窗口句柄就绪后设置样式：加 TOOLWINDOW、去 APPWINDOW
$window.Add_SourceInitialized({
  $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
  $ex = [WidTool.Native]::GetWindowLong($hwnd, -20)
  [void][WidTool.Native]::SetWindowLong($hwnd, -20, ($ex -bor 0x80) -band (-bnot 0x40000))
})

# 用 Show() + Dispatcher.Run() 而不是 ShowDialog()：
# ShowDialog 在 Hide() 后会返回，导致脚本结束、进程退出。
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
