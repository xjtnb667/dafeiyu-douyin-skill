param(
  [Parameter(Mandatory = $true)][ValidateSet('start','status','reddots','dms','messages','open','chat','send','quote-send','media-open','share-list','share-open','share-read','share-close','share-watch','watch','search','note-page','reply-comment','counter','tick','ui','dock','dmback','dmreply')][string]$cmd,
  [string]$arg = '',
  [string]$arg2 = '',
  [int]$n = 10
)

# ASCII-only on purpose: PowerShell 5.1 reads .ps1 as ANSI when there is no BOM,
# which corrupts UTF-8 literals. Pass Chinese text in via -arg / -Theme.

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$repoRoot   = Split-Path -Parent $scriptRoot
$cdpScript  = Join-Path $scriptRoot 'cdp.ps1'

$edgeBin = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe','C:\Program Files\Microsoft\Edge\Application\msedge.exe') |
  Where-Object { Test-Path $_ } | Select-Object -First 1

$profileDir = if ($env:DY_PROFILE) { $env:DY_PROFILE } else { Join-Path $repoRoot 'browser-profile' }
$stateDir   = Join-Path $repoRoot 'state'

foreach ($p in @($profileDir, $stateDir, (Join-Path $stateDir 'logs'))) {
  if (-not (Test-Path $p)) { try { New-Item -ItemType Directory -Path $p -Force | Out-Null } catch { } }
}

function InvokeCdp([string]$c, [string]$a = '') { & $cdpScript -cmd $c -arg $a }
function EvalJs([string]$expr) { InvokeCdp 'js' $expr }
function GetCenter([string]$jsExpr) {
  $expr = '(()=>{const it=' + $jsExpr + ';if(!it)return "";const r=it.getBoundingClientRect();return Math.round(r.x+r.width/2)+","+Math.round(r.y+r.height/2)})()'
  return ((EvalJs $expr) -replace '"','')
}

# ---- outbound message counter (纯统计，不额外发送任何内容) ----
$configFile  = Join-Path $repoRoot 'config.json'
$counterFile = Join-Path $stateDir 'message-counter.json'

# ---- 号主身份：config.owner.name / aliases。会话命中即视为“用户本人”，其消息=指令 ----
# ---- 默认主题：config.theme（刷视频关键词），未配置时回落到 'douyin' ----
$script:OwnerNames = @()
$script:ThemeDefault = 'douyin'
if (Test-Path $configFile) {
  try {
    $ct = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ct.owner) {
      if ($ct.owner.name) { $script:OwnerNames += [string]$ct.owner.name }
      if ($ct.owner.aliases) { foreach ($a in $ct.owner.aliases) { if ($a) { $script:OwnerNames += [string]$a } } }
    }
    if ($ct.theme) { $script:ThemeDefault = [string]$ct.theme }
    elseif ($ct.themes) {
      $firstTheme = @($ct.themes) | Where-Object { $_ } | Select-Object -First 1
      if ($firstTheme) { $script:ThemeDefault = [string]$firstTheme }
    }
  } catch { }
}
$script:OwnerNames = @($script:OwnerNames | Where-Object { $_ } | Select-Object -Unique)
function Test-OwnerName([string]$n) {
  if (-not $n) { return $false }
  foreach ($o in $script:OwnerNames) { if ($n.Trim() -eq $o) { return $true } }
  return $false
}

function Get-SentCount {
  if (-not (Test-Path $counterFile)) { return 0 }
  try { return [int]((Get-Content $counterFile -Raw -Encoding UTF8 | ConvertFrom-Json).sent) } catch { return 0 }
}

function Set-SentCount([int]$v) {
  @{ sent = $v; updated_at = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content -Path $counterFile -Encoding UTF8
}

# 计数 +1（仅统计已发出的消息条数，供 -cmd counter 查看；不做任何附加发送）
function After-Sent {
  $n = (Get-SentCount) + 1
  Set-SentCount $n
  return ''
}

# =====================================================================
# 三栏常驻（dock）: feed + comment panel + DM list panel, no /chat jump
#   why: douyin.com/chat is a separate page; every DM there costs a full
#   navigation. In the feed you can dock a video comment panel (stays while
#   you scroll) and open the message panel on top of it; clicking a
#   conversation swaps the list for the chat *inside* that panel, and the
#   back chevron at the panel's top-left returns to the list.
#   Two contenteditable boxes then coexist -> every editor lookup MUST be
#   scoped, otherwise text lands in the comment box (this file used to do
#   exactly that).
# =====================================================================

$jsUiState = '(()=>{const vis=e=>{if(!e)return false;const r=e.getBoundingClientRect();return r.width>0&&r.height>0};const url=location.href;const items=[...document.querySelectorAll("[data-e2e=conversation-item]")].filter(vis).length;const dlg=vis(document.querySelector("[data-e2e=im-dialog]"))?1:0;const entry=[...document.querySelectorAll("[data-e2e=im-entry]")].filter(vis).length>0||[...document.querySelectorAll("div,span,a")].some(e=>vis(e)&&/^\u6d88\u606f/.test((e.innerText||"").trim()));const tab=[...document.querySelectorAll("div,span")].filter(e=>vis(e)&&/^\u8bc4\u8bba\(\d+\)$/.test((e.innerText||"").trim())).length>0;const chat=(vis(document.querySelector(".messageMessageListlist"))||vis(document.querySelector(".messageEditorinputArea")))?1:0;const sf=!!(document.activeElement&&(document.activeElement.getAttribute("placeholder")==="\u641c\u7d22"||/search/i.test(String(document.activeElement.className||""))))?1:0;const v=document.querySelector("video");return (/\/chat/.test(url)?1:0)+"|"+items+"|"+dlg+"|"+(entry?1:0)+"|"+(tab?1:0)+"|"+(!!v&&!v.paused?1:0)+"|"+chat+"|"+sf+"|"+url.slice(0,90)})()'

function Get-UiState {
  $s = ((EvalJs $jsUiState) -replace '"', '')
  $p = $s -split '\|'
  if ($p.Count -lt 9) { return $null }
  return [pscustomobject]@{
    isChat       = ($p[0] -eq '1')
    items        = [int]$p[1]
    dialog       = ($p[2] -eq '1')   # 注意：[data-e2e=im-dialog] 是「整个私信面板」，不是聊天框
    imEntry      = ($p[3] -eq '1')
    commentPanel = ($p[4] -eq '1')
    playing      = ($p[5] -eq '1')
    chat         = ($p[6] -eq '1')   # 真聊天框：有消息列表或聊天编辑器
    searchFocused = ($p[7] -eq '1')  # 搜索框拿到焦点 = 列表被搜索结果顶掉
    url          = $p[8]
  }
}

# Center of the chat input box ONLY inside the IM dialog (never the comment box).
function Get-ChatEditorCenter {
  $js = '(()=>{const d=document.querySelector("[data-e2e=im-dialog]");if(!d)return "";const eds=[...d.querySelectorAll("div[contenteditable=true]")].filter(e=>e.getBoundingClientRect().width>0);if(!eds.length)return "";const r=eds[0].getBoundingClientRect();return Math.round(r.x+r.width/2)+","+Math.round(r.y+r.height/2)})()'
  return ((EvalJs $js) -replace '"', '')
}

# Center of a comment editor (inside the comment panel, NOT the IM dialog).
function Get-CommentEditorCenter {
  $js = '(()=>{const d=document.querySelector("[data-e2e=im-dialog]");const eds=[...document.querySelectorAll("div[contenteditable=true]")].filter(e=>{if(e.getBoundingClientRect().width<=0)return false;if(d&&d.contains(e))return false;return true});if(!eds.length)return "";const r=eds[0].getBoundingClientRect();return Math.round(r.x+r.width/2)+","+Math.round(r.y+r.height/2)})()'
  return ((EvalJs $js) -replace '"', '')
}

# Click a conversation row in the docked DM list; returns "x,y" or "".
function Open-Conversation([string]$who) {
  if ($who -match '^\d+$') {
    return (GetCenter ('[...document.querySelectorAll("[data-e2e=conversation-item]")].filter(e=>e.getBoundingClientRect().width>0)[' + [int]$who + ']'))
  }
  $nm = $who.Replace('\', '\\').Replace("'", "\'")
  $jsFind = "(()=>{const items=[...document.querySelectorAll('[data-e2e=conversation-item]')].filter(e=>e.getBoundingClientRect().width>0);const hit=items.find(e=>((e.innerText||'').split('\n')[0]||'').replace(/\d{1,4}$/,'').trim()==='$nm');if(!hit)return '';const r=hit.getBoundingClientRect();return Math.round(r.x+r.width/2)+','+Math.round(r.y+r.height/2)})()"
  return ((EvalJs $jsFind) -replace '"', '')
}

# Click the back chevron at the chat panel's top-left; returns ok|xy or fail|why
$jsBack = '(()=>{const vis=e=>{if(!e)return false;const r=e.getBoundingClientRect();return r.width>4&&r.height>4};const panel=document.querySelector("[data-e2e=im-dialog]");if(!panel)return "fail|no-chat";const pr=panel.getBoundingClientRect();let cands=[...panel.querySelectorAll("[aria-label],[title],[class*=back],[class*=Back],[data-e2e]")].filter(e=>vis(e)&&/back|\u8fd4\u56de/i.test((e.getAttribute("aria-label")||"")+(e.getAttribute("title")||"")+(e.getAttribute("data-e2e")||"")+(String(e.className||""))));if(!cands.length){cands=[...panel.querySelectorAll("div,span,svg,button")].filter(e=>{const r=e.getBoundingClientRect();return vis(e)&&r.width>8&&r.width<56&&r.height>8&&r.height<56&&r.x<pr.x+70&&r.y<pr.y+80});}cands=cands.filter(e=>{if(e.tagName==="INPUT"||e.tagName==="TEXTAREA")return false;let n=e;for(let i=0;i<4&&n;i++){const c=String(n.className&&n.className.baseVal===undefined?n.className:n.className.baseVal);if(/search/i.test(c))return false;n=n.parentElement}return true});if(!cands.length)return "fail|no-back-btn";const e=cands[0];const r=e.getBoundingClientRect();return "ok|"+Math.round(r.x+r.width/2)+","+Math.round(r.y+r.height/2)})()'

$jsIm = '(()=>{const e=document.querySelector("[data-e2e=im-entry]");const s=e?(e.innerText||"").replace(/\n/g,""):"";const m=s.match(/\d+/);return JSON.stringify({raw:s,unread:!!m,n:m?Number(m[0]):0})})()'

switch ($cmd) {
  'start' {
    if (-not $edgeBin) { throw 'msedge.exe not found' }
    # A killed browser leaves Chrome profile locks behind -> next start dies with exit code 21.
    Get-ChildItem $profileDir -Force -Filter 'Singleton*' -ErrorAction SilentlyContinue |
      Remove-Item -Force -ErrorAction SilentlyContinue
    # never pass --disable-gpu / --headless here: shared video/gallery needs GPU compositing, otherwise it renders black.
    Start-Process $edgeBin -ArgumentList '--remote-debugging-port=9222',"--user-data-dir=$profileDir",'--profile-directory=Default','--no-first-run','--start-maximized','--autoplay-policy=no-user-gesture-required','https://www.douyin.com/?recommend=1' | Out-Null
    Start-Sleep -Seconds 10
    EvalJs '(()=>JSON.stringify({url:location.href,logged_in:!/\u767b\u5f55|\u626b\u7801/.test(document.body.innerText.slice(0,300))}))()'
  }

  'status' {
    EvalJs '(()=>{const e=document.querySelector("[data-e2e=im-entry]");return JSON.stringify({url:location.href,im:e?e.innerText.replace(/\n/g,""):null})})()'
  }

  'reddots' { EvalJs $jsIm }

  'dms' {
    # name/flame/unread are three different things:
    #   text right after the nickname  = 火花天数 (streak days, NOT unread)
    #   red badge under the message time = 未读条数
    $js = '(()=>{const items=[...document.querySelectorAll("[data-e2e=conversation-item]")].filter(e=>e.getBoundingClientRect().width>0);return JSON.stringify(items.map((e,i)=>{const r=e.getBoundingClientRect();const t=(e.innerText||"").replace(/\n/g,"|");let unread=0;const cands=[...e.querySelectorAll("*")].filter(n=>{const txt=(n.textContent||"").trim();if(!/^\d{1,3}$/.test(txt))return false;if(n.children.length>0)return false;const bg=getComputedStyle(n).backgroundColor||"";const m=bg.match(/^rgba?\((\d+),\s*(\d+),\s*(\d+)/);if(!m)return false;const R=+m[1],G=+m[2],B=+m[3];return R>170&&G<100&&B<120});if(cands.length){unread=parseInt(cands[cands.length-1].textContent.trim(),10)}let flame=0;const fx=[...e.querySelectorAll("*")].filter(n=>{const txt=(n.textContent||"").trim();if(!/^\d{1,4}$/.test(txt))return false;if(n.children.length>0)return false;const c=(n.className||"").toString();return /flame|spark|hot|fire|streak|hotspot/i.test(c)});if(fx.length){flame=parseInt(fx[fx.length-1].textContent.trim(),10)}const first=t.split("|")[0];const nm=first.match(/^(.*?)(\d{1,4})$/);const name=(nm?nm[1]:first).trim();if(!flame&&nm&&!/^\d{1,4}$/.test(first)){flame=parseInt(nm[2],10)}return {i:i,name:name,flame:flame,unread:unread,preview:t.slice(0,70),x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}}))})()'
    $raw = EvalJs $js
    try {
      $arr = @($raw | ConvertFrom-Json)
      foreach ($o in $arr) {
        $isOwner = Test-OwnerName ([string]$o.name)
        $o | Add-Member -NotePropertyName owner -NotePropertyValue $isOwner -Force
        $o | Add-Member -NotePropertyName needs_reply -NotePropertyValue ([int]$o.unread -gt 0) -Force
      }
      ($arr | ConvertTo-Json -Depth 6 -Compress)
    } catch { $raw }
  }

    'open' {
    if ($arg -match '^\d+$') {
      $c = GetCenter ('[...document.querySelectorAll("[data-e2e=conversation-item]")].filter(e=>e.getBoundingClientRect().width>0)[' + [int]$arg + ']')
    } else {
      # 按名字打开（如 -cmd open -arg 张三）
      $nm = $arg.Replace('\', '\\').Replace("'", "\'")
      $jsFind = "(()=>{const items=[...document.querySelectorAll('[data-e2e=conversation-item]')].filter(e=>e.getBoundingClientRect().width>0);const hit=items.find(e=>((e.innerText||'').split('\n')[0]||'').replace(/\d{1,4}$/,'').trim()==='$nm');if(!hit)return '';const r=hit.getBoundingClientRect();return Math.round(r.x+r.width/2)+','+Math.round(r.y+r.height/2)})()"
      $c = ((EvalJs $jsFind) -replace '"', '')
    }
    if (-not $c) { 'NOTFOUND'; break }
    InvokeCdp 'ipoint' $c
  }

  'lastside' {
    # 当前会话最后一条是谁说的：mine / theirs / unknown（用于 unread=0 但可能是对方结尾的情况）
    $jsSide = '(()=>{const d=document.querySelector("[data-e2e=im-dialog]");if(!d)return JSON.stringify({err:"no-dialog"});const dr=d.getBoundingClientRect();const mid=dr.x+dr.width/2;const bs=[...d.querySelectorAll("[class*=messageBox]")].map(b=>{const r=b.getBoundingClientRect();return {y:Math.round(r.y),x:Math.round(r.x),w:Math.round(r.width),t:(b.innerText||"").replace(/\n/g," ").trim().slice(0,60)}}).filter(o=>o.t&&o.w>10).sort((a,b)=>a.y-b.y);if(!bs.length)return JSON.stringify({side:"unknown"});const last=bs[bs.length-1];return JSON.stringify({side:(last.x>mid?"mine":"theirs"),txt:last.t,y:last.y})})()'
    EvalJs $jsSide
  }

  'chat' {
    $expr = '(()=>{const d=document.querySelector("[data-e2e=im-dialog]");if(!d)return JSON.stringify({err:"no-dialog"});const boxes=[...d.querySelectorAll("[class*=messageBox]")].map(b=>{const r=b.getBoundingClientRect();return {y:Math.round(r.y),txt:(b.innerText||"").replace(/\n/g," ").trim()}}).filter(o=>o.txt).sort((a,b)=>a.y-b.y);return JSON.stringify(boxes.slice(-' + $n + '))})()'
    EvalJs $expr
  }

  'send' {
    # scoped on purpose: with the comment panel docked there are TWO contenteditable
    # boxes on screen; the old global lookup could type into the comment box.
    if (-not $arg) { throw 'arg = text to send' }
    $c = Get-ChatEditorCenter
    if (-not $c) { 'NO_CHAT_OPEN'; break }
    [void](InvokeCdp 'ipoint' $c)
    Start-Sleep -Milliseconds 500
    [void](InvokeCdp 'itext' $arg)
    Start-Sleep -Milliseconds 400
    [void](InvokeCdp 'ikey' 'Enter')
    Start-Sleep -Seconds 2
    [void](After-Sent)
    $probe = if ($arg.Length -gt 16) { $arg.Substring(0, 16) } else { $arg }
    $probeJs = ($probe -replace '[\r\n]+', ' ') | ConvertTo-Json -Compress
    $hit = ((EvalJs ("(()=>{const d=document.querySelector('[data-e2e=im-dialog]');return d?((d.innerText||'').replace(/\\s+/g,' ').includes(" + $probeJs + ")):false})()")) -replace '"', '')
    if ($hit -eq 'true') { 'sent' } else { 'sent-UNVERIFIED' }
  }

  'search' {
    $kw = if ($arg) { $arg } elseif ($script:ThemeDefault) { $script:ThemeDefault } else { 'douyin' }
    $enc = [uri]::EscapeDataString($kw)
    EvalJs ('(()=>{location.href="https://www.douyin.com/search/' + $enc + '?type=video";return "go"})()') | Out-Null
    Start-Sleep -Seconds 9
    'searched'
  }

  'watch' {
    $kw = if ($arg) { $arg } elseif ($script:ThemeDefault) { $script:ThemeDefault } else { 'douyin' }
    $enc = [uri]::EscapeDataString($kw)
    EvalJs ('(()=>{location.href="https://www.douyin.com/search/' + $enc + '?type=video";return "go"})()') | Out-Null
    Start-Sleep -Seconds 9
    $c = GetCenter '[...document.querySelectorAll("a")].filter(e=>/\/video\//.test(e.getAttribute("href")||"")&&e.getBoundingClientRect().width>100)[0]'
    if (-not $c) { 'NO_RESULT'; break }
    InvokeCdp 'ipoint' $c | Out-Null
    Start-Sleep -Seconds 6
    EvalJs '(()=>{const v=document.querySelector("video");return JSON.stringify({playing:!!v&&!v.paused,t:v?Math.round(v.currentTime):null,d:v?Math.round(v.duration):null})})()'
  }

  'note-page' {
    $u = if ($arg -match '^https?://') { $arg } else { 'https://www.douyin.com/note/' + $arg }
    EvalJs ('(()=>{location.href="' + $u + '";return "go"})()') | Out-Null
    Start-Sleep -Seconds 9
    EvalJs '(()=>JSON.stringify({url:location.href.slice(0,60)}))()'
  }

  'reply-comment' {
    # 回复评论（正确姿势）：定位那条评论（含它的「时间 · IP」行），点该行下方动作栏里的「回复」
    # -arg  = 回复内容
    # -arg2 = 目标评论的关键字（可选；给了就按文字匹配，不给就回第一条）
    if (-not $arg) { throw 'arg = reply text' }
    $target = if ($arg2) { $arg2 } else { '' }

    # 1) 切到「评论(n)」tab
    EvalJs '(()=>{const t=[...document.querySelectorAll("div,span")].filter(e=>{const s=(e.innerText||"").trim();const r=e.getBoundingClientRect();return /^\u8bc4\u8bba\(\d+\)$/.test(s)&&r.width>30});if(t[0])t[0].click();return t.length})()' | Out-Null
    Start-Sleep -Seconds 2

    # 2) 找该评论自己那条动作栏里的「回复」（位置在「时间 · IP」下方，不是整页第一个）
    $pickJs = @"
(()=>{const T='$target';
 const reps=[...document.querySelectorAll('div,span,button')].filter(e=>{const t=(e.innerText||'').trim();const r=e.getBoundingClientRect();return t==='\u56de\u590d'&&r.width>0&&r.width<80&&r.height>8&&r.height<32});
 if(!reps.length)return '';
 const timeRe=/(\d+\s*(分钟|小时|天)前|昨天|刚刚|\d{2}-\d{2}|\d{4}-\d{2}-\d{2})/;
 const info=reps.map(e=>{let a=e,txt='';for(let i=0;i<7&&a;i++){a=a.parentElement;if(!a)break;const s=(a.innerText||'').replace(/\n/g,' ');if(s.length>txt.length)txt=s;}const r=e.getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2),txt:txt.slice(0,200)}});
 const pool=info.filter(o=>timeRe.test(o.txt)); const use=pool.length?pool:info;
 let pick=use[0];
 if(T){const hit=use.filter(o=>o.txt.includes(T)); if(hit.length)pick=hit[hit.length-1];}
 return pick.x+','+pick.y})()
"@
    $xy = ((EvalJs $pickJs) -replace '"', '')
    if (-not $xy -or $xy -notmatch '^\d+,\d+$') { 'NO_REPLY_BTN'; break }

    # 3) 点「回复」→ 出现「回复 @xxx」引用条
    [void](InvokeCdp 'mousemove' $xy)
    Start-Sleep -Milliseconds 300
    [void](InvokeCdp 'ipoint' $xy)
    Start-Sleep -Milliseconds 900
    $bar = ((EvalJs '(()=>{const eds=[...document.querySelectorAll("div[contenteditable=true]")].filter(e=>e.getBoundingClientRect().width>0);if(!eds.length)return "no_editor";const box=eds[0].closest("div[class]")||eds[0].parentElement;return (box.innerText||"").includes("\u56de\u590d")?"quoted":"no_bar"})()') -replace '"', '')

    # 4) 写字（评论框：显式排除私信面板里的输入框）
    $c = Get-CommentEditorCenter
    if (-not $c) { 'NO_EDITOR'; break }
    [void](InvokeCdp 'ipoint' $c)
    Start-Sleep -Milliseconds 300
    [void](InvokeCdp 'itext' $arg)
    Start-Sleep -Milliseconds 700

    # 5) 点红色圆形 ↑ 发送键（定位：编辑器右侧、红色底、直径 20~48）
    $sendJs = @"
(()=>{const eds=[...document.querySelectorAll('div[contenteditable=true]')].filter(e=>e.getBoundingClientRect().width>0);if(!eds.length)return '';
 const r=eds[0].getBoundingClientRect();
 const cands=[...document.querySelectorAll('div,span,button')].map(e=>{const b=e.getBoundingClientRect();if(b.width<20||b.width>48||b.height<20||b.height>48)return null;if(b.x<r.right-10||Math.abs(b.y+b.height/2-(r.y+r.height/2))>45)return null;
 const bg=getComputedStyle(e).backgroundColor||'';const m=bg.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/);if(!m)return null;const R=+m[1],G=+m[2],B=+m[3];
 return (R>190&&G<110&&B<130)?{x:Math.round(b.x+b.width/2),y:Math.round(b.y+b.height/2)}:null}).filter(Boolean);
 if(!cands.length)return '';
 const c=cands[cands.length-1];return c.x+','+c.y})()
"@
    $sc = ((EvalJs $sendJs) -replace '"', '')
    if (-not $sc -or $sc -notmatch '^\d+,\d+$') { 'NO_SEND_BTN'; break }
    [void](InvokeCdp 'ipoint' $sc)
    Start-Sleep -Seconds 3

    $sent = $false
    for ($k = 0; $k -lt 3; $k++) {
      $chk = ((EvalJs ("(()=>{const t=document.body.innerText;return t.includes(" + (($arg | ConvertTo-Json -Compress)) + ")})()")) -replace '"', '')
      if ($chk -eq 'true') { $sent = $true; break }
      Start-Sleep -Milliseconds 1200
    }
    if ($bar -eq 'quoted') { if ($sent) { 'comment-quoted-sent' } else { 'comment-quoted-UNVERIFIED' } }
    else { if ($sent) { 'comment-sent(no_quote_bar)' } else { 'comment-UNVERIFIED' } }
  }

    'messages' {
    EvalJs '(()=>{const d=document.querySelector("[data-e2e=im-dialog]");if(!d)return JSON.stringify({err:"no-dialog"});const dr=d.getBoundingClientRect();const mid=dr.x+dr.width/2;const bs=[...d.querySelectorAll("[class*=messageBox]")].map(b=>{const r=b.getBoundingClientRect();return {y:Math.round(r.y),x:Math.round(r.x),w:Math.round(r.width),t:(b.innerText||"").replace(/\n/g," ").trim()}}).filter(o=>o.t&&o.w>20).sort((a,b)=>a.y-b.y);return JSON.stringify(bs.slice(-' + $n + ').map(o=>({y:o.y,mine:o.x>mid,txt:o.t.slice(0,70)})))})()'
  }

  'quote-send' {
    # 引用回复（正确姿势）：
    #   1) 鼠标移到要回的那条消息上（悬停，气泡操作条/更多按钮才出现）
    #   2) 右键 → 弹菜单 → 点「回复」
    #   3) 输入框上方出现「回复 @xxx」引用条 → 输入 → Enter
    # 任一步失败逐级降级：悬停工具条「回复」→ 文本前缀说明。
    if (-not $arg) { throw 'arg = reply text' }
    $msgJs = '(()=>{const d=document.querySelector("[data-e2e=im-dialog]");if(!d)return "";const dr=d.getBoundingClientRect();const mid=dr.x+dr.width/2;const bs=[...d.querySelectorAll("[class*=messageBox]")].map(b=>{const r=b.getBoundingClientRect();return {y:Math.round(r.y),x:Math.round(r.x),w:Math.round(r.width),h:Math.round(r.height),t:(b.innerText||"").replace(/\n/g," ").trim()}}).filter(o=>o.t&&o.w>20).sort((a,b)=>a.y-b.y);const others=bs.filter(o=>o.x<mid);if(!others.length)return "";const m=others[others.length-1];return Math.round(m.x+m.w/2)+","+Math.round(m.y+m.h/2)+"|"+m.t.slice(0,30)})()'
    $msg = ((EvalJs $msgJs) -replace '"', '')
    if (-not $msg -or $msg -notmatch '^\d+,\d+\|') { 'NO_TARGET_MSG'; break }
    $parts = $msg.Split('|', 2)
    $xy = $parts[0]; $summary = $parts[1]

    # 1) 悬停 → 右键
    [void](InvokeCdp 'rclick' $xy)
    Start-Sleep -Milliseconds 900

    # 2) 找右键菜单里的「回复」
    $menuJs = '(()=>{const els=[...document.querySelectorAll("div,span,li,button")].filter(e=>{const t=(e.innerText||"").trim();const r=e.getBoundingClientRect();return t==="\u56de\u590d"&&r.width>0&&r.width<120&&r.height>0});if(!els.length)return "";const e=els[els.length-1];const r=e.getBoundingClientRect();return Math.round(r.x+r.width/2)+","+Math.round(r.y+r.height/2)})()'
    $rc = ((EvalJs $menuJs) -replace '"', '')
    $quoted = $false

    if ($rc -match '^\d+,\d+$') {
      [void](InvokeCdp 'ipoint' $rc)
      Start-Sleep -Milliseconds 700
      $bar = ((EvalJs '(()=>{const eds=[...document.querySelectorAll("div[contenteditable=true]")].filter(e=>e.getBoundingClientRect().width>0);if(!eds.length)return "no_editor";const box=eds[0].closest("div[class]")||eds[0].parentElement;return (box.innerText||"").includes("\u56de\u590d")?"quoted":"no_bar"})()') -replace '"', '')
      if ($bar -eq 'quoted') { $quoted = $true }
    }

    # 2b) 降级：不弹菜单时，用悬停工具条上的「回复」
    if (-not $quoted) {
      [void](InvokeCdp 'mousemove' $xy)
      Start-Sleep -Milliseconds 700
      $hoverBtn = ((EvalJs '(()=>{const els=[...document.querySelectorAll("div,span,button")].filter(e=>{const t=(e.innerText||"").trim();const r=e.getBoundingClientRect();return t==="\u56de\u590d"&&r.width>0&&r.width<60});if(!els.length)return "";const e=els[els.length-1];const r=e.getBoundingClientRect();return Math.round(r.x+r.width/2)+","+Math.round(r.y+r.height/2)})()') -replace '"', '')
      if ($hoverBtn -match '^\d+,\d+$') {
        [void](InvokeCdp 'ipoint' $hoverBtn)
        Start-Sleep -Milliseconds 600
        $bar2 = ((EvalJs '(()=>{const eds=[...document.querySelectorAll("div[contenteditable=true]")].filter(e=>e.getBoundingClientRect().width>0);if(!eds.length)return "no_editor";const box=eds[0].closest("div[class]")||eds[0].parentElement;return (box.innerText||"").includes("\u56de\u590d")?"quoted":"no_bar"})()') -replace '"', '')
        if ($bar2 -eq 'quoted') { $quoted = $true }
      }
    }

    # 3) 彻底失败 → 文本里带上被引用的摘录
    if (-not $quoted) { $arg = ('回你那条「' + $summary + '」：') + $arg }

    $c = Get-ChatEditorCenter
    if (-not $c) { 'NO_CHAT_OPEN'; break }
    [void](InvokeCdp 'ipoint' $c)
    Start-Sleep -Milliseconds 400
    [void](InvokeCdp 'itext' $arg)
    Start-Sleep -Milliseconds 400
    [void](InvokeCdp 'ikey' 'Enter')
    Start-Sleep -Seconds 2
    [void](After-Sent)
    if ($quoted) { 'quoted-sent' } else { 'DEGRADE_QUOTE-sent' }
  }

    'share-list' {
    $js = '(()=>{const d=document.querySelector("[data-e2e=im-dialog]");if(!d)return JSON.stringify({err:"no-dialog"});const dr=d.getBoundingClientRect();const mid=dr.x+dr.width/2;const bs=[...d.querySelectorAll("[class*=messageBox]")].map(b=>{const r=b.getBoundingClientRect();const t=(b.innerText||"").replace(/\n/g," ").trim();return {x:Math.round(r.x),y:Math.round(r.y),w:Math.round(r.width),h:Math.round(r.height),t:t}}).filter(o=>o.t&&o.w>20).sort((a,b)=>a.y-b.y);const out=bs.filter(o=>o.x<mid).map((o,i)=>({i:i,mine:false,share:/\u5206\u4eab|\[.{0,6}\]|https?:\/\//.test(o.t),txt:o.t.slice(0,80),cx:Math.round(o.x+o.w/2),cy:Math.round(o.y+o.h/2)}));return JSON.stringify(out.slice(-8))})()'
    EvalJs $js
  }

  'share-open' {
    # 引用卡片形如「[分享图集]」/「[分享视频]」：先把光标悬停到卡片上，再单击一次打开。
    $before = @((InvokeCdp 'pages') | ConvertFrom-Json | ForEach-Object { $_.id })
    $js = '(()=>{const d=document.querySelector("[data-e2e=im-dialog]");if(!d)return "";const bs=[...d.querySelectorAll("[class*=messageBox]")].map(b=>{const r=b.getBoundingClientRect();const t=(b.innerText||"").replace(/\n/g," ").trim();return {x:Math.round(r.x),y:Math.round(r.y),w:Math.round(r.width),h:Math.round(r.height),t:t}}).filter(o=>o.t&&o.w>20).sort((a,b)=>a.y-b.y);const re=/\[?\u5206\u4eab(\u56fe\u96c6|\u56f5\u96c6|\u89c6\u9891)\]?/;let cands=bs.filter(o=>re.test(o.t));if(!cands.length)cands=bs.filter(o=>/\u5206\u4eab|\[.{0,6}\]/.test(o.t));if(!cands.length)return "";const m=cands[cands.length-1];const kind=re.test(m.t)?(m.t.match(re)[1]=="\u89c6\u9891"?"video":"gallery"):"other";return Math.round(m.x+m.w/2)+","+Math.round(m.y+m.h/2)+"|"+kind+"|"+m.t.slice(0,60)})()'
    $s2 = ((EvalJs $js) -replace '"', '')
    if (-not $s2 -or $s2 -notmatch '^\d+,\d+\|') { 'NO_SHARE_MSG'; break }
    $sp = $s2.Split('|', 3)
    $kind = if ($sp.Count -ge 2) { $sp[1] } else { 'other' }
    $preview = if ($sp.Count -ge 3) { $sp[2] } else { '' }

    # 视频/图集：先 hover 停留 ~900ms 让封面上的播放/进入按钮浮出来，再单次点击
    if ($kind -eq 'video' -or $kind -eq 'gallery') {
      [void](InvokeCdp 'hoverclick' $sp[0])
    } else {
      [void](InvokeCdp 'ipoint' $sp[0])
    }
    Start-Sleep -Seconds 5

    $pages = @((InvokeCdp 'pages') | ConvertFrom-Json)
    $new = @($pages | Where-Object { $before -notcontains $_.id -and ($_.url -match '/video/|/note/|/gallery/' ) })
    $tgt = if ($new.Count -gt 0) { $new[0] } else { @($pages | Where-Object { $_.url -match '/video/|/note/' }) | Select-Object -First 1 }
    if (-not $tgt) {
      (@{ ok = $true; mode = 'modal'; kind = $kind; preview = $preview; url = (EvalJs 'location.href') } | ConvertTo-Json -Compress)
      break
    }
    $stateFile = Join-Path $stateDir 'share-target.json'
    (@{ id = $tgt.id; url = $tgt.url; title = $tgt.title; kind = $kind; preview = $preview; at = (Get-Date).ToString('s') } | ConvertTo-Json -Compress) | Set-Content -Path $stateFile -Encoding UTF8
    (@{ ok = $true; mode = 'tab'; kind = $kind; url = $tgt.url; title = $tgt.title; preview = $preview } | ConvertTo-Json -Compress)
  }

  'share-read' {
    # read the content of the opened share target: metadata + caption + comments + played frames (+OCR)
    $stateFile = Join-Path $stateDir 'share-target.json'
    $hasState = Test-Path $stateFile
    if ($hasState) {
      $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $env:DY_TARGET_MATCH = $(if ($st.url) { ($st.url -split '\?')[0] } else { '/video/' })
    }
    try {
      $metaJs = '(()=>{const q=s=>document.querySelector(s);const meta=n=>{const e=q(`meta[property="${n}"]`)||q(`meta[name="${n}"]`);return e?e.getAttribute("content"):null};const body=document.body.innerText.replace(/\n+/g," | ");const v=q("video");const pick=[...document.querySelectorAll("[data-e2e=video-desc],[data-e2e=note-desc],h1,span")].map(e=>(e.innerText||"").trim()).filter(t=>t.length>8&&t.length<300).slice(0,6);return JSON.stringify({url:location.href,title:document.title.slice(0,120),og:meta("og:description")||meta("description"),duration:v?Math.round(v.duration):null,playing:v?(!v.paused):null,caption:pick,bodyTail:body.slice(-1500)})})()'
      $meta = EvalJs $metaJs

      # try to make it play (muted autoplay is usually allowed)
      EvalJs '(()=>{const v=document.querySelector("video");if(!v)return "no-video";try{v.muted=true;v.play&&v.play();}catch(e){}return "play:"+(!v.paused)})()' | Out-Null

      $want = if ($n -gt 0) { $n } else { 6 }
      $hasVideo = ((EvalJs '(()=>!!document.querySelector("video"))()') -match 'true')
      $frames = @()
      $frameDir = Join-Path $env:TEMP ('dy_share_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
      New-Item -ItemType Directory -Path $frameDir -Force | Out-Null
      for ($i = 1; $i -le $want; $i++) {
        if (-not $hasVideo -and $i -gt 1) { InvokeCdp 'ikey' 'ArrowRight' | Out-Null }  # gallery: next image
        Start-Sleep -Seconds $(if ($hasVideo) { 3 } else { 1 })
        $fp = Join-Path $frameDir ("f$i.png")
        InvokeCdp 'shot' $fp | Out-Null
        $frames += $fp
      }
      $pos = EvalJs '(()=>{const v=document.querySelector("video");return JSON.stringify({t:v?Math.round(v.currentTime):null,d:v?Math.round(v.duration):null,paused:v?v.paused:null})})()'

      # OCR every frame (best effort; Windows.Media.Ocr via powershell.exe 5.1)
      $ocrText = @()
      $ocrOk = $false
      $ocrScript = Join-Path $scriptRoot 'ocr.ps1'
      if (Test-Path $ocrScript) {
        foreach ($fp in $frames) {
          try {
            $lines = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ocrScript -Path $fp 2>$null
            if ($lines) {
              $ocrOk = $true
              foreach ($ln in @($lines)) {
                $l = ([string]$ln).Trim()
                if ($l.Length -ge 2) { $ocrText += $l }
              }
            }
          } catch { }
        }
      }
      $uniq = @($ocrText | Where-Object { $_ -match '[\u4e00-\u9fa5A-Za-z0-9]' } | Select-Object -Unique)
      Remove-Item $frameDir -Recurse -Force -ErrorAction SilentlyContinue

      (@{ ok = $true; meta = (($meta -replace '^"|"$', '') | ConvertFrom-Json); position = (($pos -replace '^"|"$', '') | ConvertFrom-Json); ocr_ok = $ocrOk; ocr_lines = @($uniq | Select-Object -First 40) } | ConvertTo-Json -Depth 6 -Compress)
    }
    finally {
      $env:DY_TARGET_MATCH = ''
    }
  }

  'share-close' {
    $stateFile = Join-Path $stateDir 'share-target.json'
    if (-not (Test-Path $stateFile)) { 'no-target'; break }
    $st = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $r = InvokeCdp 'close' $st.id
    # fall back to closing whichever tab matches the video/note url
    if ($r -notmatch 'closed=true') {
      $env:DY_TARGET_MATCH = '/video/'
      $r = InvokeCdp 'close' ''
      $env:DY_TARGET_MATCH = ''
    }
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    'closed ' + $r
  }

  'share-watch' {
    # one-shot: open newest share -> read content (metadata + frames OCR) -> close -> print digest JSON
    $open = & $PSCommandPath -cmd share-open
    if ($open -match 'NO_SHARE_MSG') { 'NO_SHARE_MSG'; break }
    Start-Sleep -Seconds 2
    $read = & $PSCommandPath -cmd share-read -n $n
    $close = & $PSCommandPath -cmd share-close
    (@{ open = (($open -replace '^"|"$', '') | ConvertFrom-Json); read = (($read -replace '^"|"$', '') | ConvertFrom-Json); close = $close } | ConvertTo-Json -Depth 8 -Compress)
  }

  'media-open' { & $PSCommandPath -cmd share-watch -n $n }

  'ui' {
    $st = Get-UiState
    if (-not $st) { 'NO_CDP'; break }
    (@{ url = $st.url; isChatPage = $st.isChat; dmItems = $st.items; panelOpen = $st.dialog; chatOpen = $st.chat; searchFocused = $st.searchFocused; msgEntry = $st.imEntry; commentPanel = $st.commentPanel; videoPlaying = $st.playing } | ConvertTo-Json -Compress)
  }

  'dock' {
    # -arg check -> report only ; -arg reset -> navigate to feed first
    $checkOnly = ($arg -eq 'check')
    $st = Get-UiState
    if (-not $st) { 'NO_CDP'; break }
    $trace = @()
    if ((-not $checkOnly) -and ($st.isChat -or $arg -eq 'reset')) {
      EvalJs '(()=>{location.href="https://www.douyin.com/?recommend=1";return "go"})()' | Out-Null
      Start-Sleep -Seconds 9
      $trace += 'feed'
      $st = Get-UiState
    }
    if ((-not $checkOnly) -and $st -and -not $st.commentPanel) {
      # a) right-rail comment counter: a pure number close to the right edge
      $c = ((EvalJs '(()=>{const els=[...document.querySelectorAll("div,span")].filter(e=>{const t=(e.innerText||"").trim();const r=e.getBoundingClientRect();return /^\d{1,6}$/.test(t)&&r.width>0&&r.height>0&&r.right>window.innerWidth-120&&r.y>window.innerHeight*0.18&&r.y<window.innerHeight*0.90});if(!els.length)return "";const e=els.sort((a,b)=>a.getBoundingClientRect().y-b.getBoundingClientRect().y)[0];const r=e.getBoundingClientRect();return Math.round(r.x+r.width/2)+","+Math.round(r.y+r.height/2)})()') -replace '"', '')
      if ($c -match '^\d+,\d+$') {
        [void](InvokeCdp 'ipoint' $c)
        Start-Sleep -Seconds 3
        $trace += 'comment-rail'
        $st = Get-UiState
      }
    }
    if ((-not $checkOnly) -and $st -and -not $st.commentPanel) {
      # b) open one video, then switch its comment tab
      $c = GetCenter '[...document.querySelectorAll("a")].filter(e=>/\/video\//.test(e.getAttribute("href")||"")&&e.getBoundingClientRect().width>140)[0]'
      if ($c -match '^\d+,\d+$') {
        [void](InvokeCdp 'ipoint' $c)
        Start-Sleep -Seconds 6
        $tab = ((EvalJs '(()=>{const t=[...document.querySelectorAll("div,span")].filter(e=>{const s=(e.innerText||"").trim();const r=e.getBoundingClientRect();return /^\u8bc4\u8bba\(\d+\)$/.test(s)&&r.width>20});if(!t.length)return "";const r=t[0].getBoundingClientRect();return Math.round(r.x+r.width/2)+","+Math.round(r.y+r.height/2)})()') -replace '"', '')
        if ($tab -match '^\d+,\d+$') { [void](InvokeCdp 'ipoint' $tab); Start-Sleep -Seconds 3; $trace += 'video+tab' }
        $st = Get-UiState
      }
    }
    if ((-not $checkOnly) -and $st -and $st.items -eq 0) {
      $c = ((EvalJs '(()=>{const e=[...document.querySelectorAll("[data-e2e=im-entry]")].find(x=>x.getBoundingClientRect().width>0)||[...document.querySelectorAll("div,span,a")].find(x=>{const t=(x.innerText||"").trim();const r=x.getBoundingClientRect();return /^\u6d88\u606f/.test(t)&&r.width>0&&r.right>window.innerWidth-40});if(!e)return "";const r=e.getBoundingClientRect();return Math.round(r.x+r.width/2)+","+Math.round(r.y+r.height/2)})()') -replace '"', '')
      if ($c -match '^\d+,\d+$') {
        [void](InvokeCdp 'ipoint' $c)
        Start-Sleep -Seconds 3
        $trace += 'msg-panel'
        # 面板里那个搜索框一旦拿到焦点，列表就被搜索结果顶掉（且清空/ESC 都救不回来）
        [void]((EvalJs '(()=>{if(document.activeElement&&document.activeElement.blur)document.activeElement.blur();return 1})()'))
        Start-Sleep -Milliseconds 800
        $st = Get-UiState
        if ($st -and $st.searchFocused) {
          EvalJs '(()=>{location.href="https://www.douyin.com/?recommend=1";return "go"})()' | Out-Null
          Start-Sleep -Seconds 9
          $trace += 'reload(search)'
          $st = Get-UiState
        }
        if ($st -and $st.chat) { [void](& $PSCommandPath -cmd dmback); $st = Get-UiState }
      }
    }
    if (-not $st) { 'NO_CDP'; break }
    $ok = ($st.commentPanel -and $st.items -gt 0 -and -not $st.isChat -and -not $st.chat -and -not $st.searchFocused)
    if ($ok -and -not $checkOnly) {
      (@{ at = (Get-Date).ToString('s'); items = $st.items; url = $st.url } | ConvertTo-Json -Compress) |
        Set-Content -Path (Join-Path $stateDir 'dock.json') -Encoding UTF8
    }
    (@{ docked = $ok; steps = @($trace); commentPanel = $st.commentPanel; dmItems = $st.items; chatOpen = $st.chat; panelOpen = $st.dialog; searchFocused = $st.searchFocused; videoPlaying = $st.playing; url = $st.url } | ConvertTo-Json -Compress)
  }

  'dmback' {
    $r = ((EvalJs $jsBack) -replace '"', '')
    if ($r -notmatch '^ok\|(\d+),(\d+)$') { $r; break }
    [void](InvokeCdp 'ipoint' ($Matches[1] + ',' + $Matches[2]))
    Start-Sleep -Milliseconds 1500
    ((EvalJs '(()=>{if(document.activeElement&&document.activeElement.blur)document.activeElement.blur();return 1})()')) | Out-Null
    $st = Get-UiState
    if ($st -and $st.items -gt 0 -and -not $st.chat) { 'back-ok|' + $st.items }
    else { 'back-UNVERIFIED|chat=' + $(if ($st) { $st.chat } else { '?' }) + '|items=' + $(if ($st) { $st.items } else { '?' }) + '|search=' + $(if ($st) { $st.searchFocused } else { '?' }) }
  }

  'dmreply' {
    # one-shot: open conversation -> send -> verify -> back to list
    if (-not $arg) { throw 'arg = conversation name or index' }
    if (-not $arg2) { throw 'arg2 = text to send' }
    $st = Get-UiState
    if (-not $st) { 'NO_CDP'; break }
    if ($st.searchFocused) { 'SEARCH_BOX_FOCUSED (reload the page, then -cmd dock)'; break }
    if ($st.items -eq 0) { 'NOT_DOCKED (run -cmd dock first)'; break }
    $c = Open-Conversation $arg
    if (-not $c) { 'NOTFOUND'; break }
    [void](InvokeCdp 'ipoint' $c)
    $opened = $false
    for ($i = 0; $i -lt 8; $i++) {
      Start-Sleep -Milliseconds 500
      $s2 = Get-UiState
      if ($s2 -and $s2.chat) { $opened = $true; break }
    }
    if (-not $opened) { 'NO_CHAT_OPEN'; break }
    $e = Get-ChatEditorCenter
    if (-not $e) { [void](& $PSCommandPath -cmd dmback); 'NO_CHAT_EDITOR'; break }
    [void](InvokeCdp 'ipoint' $e)
    Start-Sleep -Milliseconds 400
    [void](InvokeCdp 'itext' $arg2)
    Start-Sleep -Milliseconds 500
    [void](InvokeCdp 'ikey' 'Enter')
    Start-Sleep -Seconds 2
    $probe = if ($arg2.Length -gt 16) { $arg2.Substring(0, 16) } else { $arg2 }
    $probeJs = ($probe -replace '[\r\n]+', ' ') | ConvertTo-Json -Compress
    $hit = ((EvalJs ("(()=>{const d=document.querySelector('[data-e2e=im-dialog]');return d?((d.innerText||'').replace(/\\s+/g,' ').includes(" + $probeJs + ")):false})()")) -replace '"', '')
    [void](After-Sent)
    $back = & $PSCommandPath -cmd dmback
    if ($hit -eq 'true') { 'dm-reply|sent|' + $back } else { 'dm-reply|UNVERIFIED|' + $back }
  }

  'counter' {
    if ($arg -eq 'reset') { Set-SentCount 0; 'counter=0' }
    else { 'counter=' + (Get-SentCount) }
  }

  'tick' {
    EvalJs '(()=>{const im=document.querySelector("[data-e2e=im-entry]");const s=im?(im.innerText||"").replace(/\n/g,""):"";const m=s.match(/\d+/);const v=document.querySelector("video");return JSON.stringify({im_raw:s,unread:!!m,n:m?Number(m[0]):0,video:{playing:!!v&&!v.paused,t:v?Math.round(v.currentTime):null,d:v?Math.round(v.duration):null},url:location.href.slice(0,80)})})()'
  }
}






