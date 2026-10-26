param(
  [Parameter(Mandatory = $true)][ValidateSet('js','nav','targets','title','click','type','shot','hover','iclick','itext','ikey','ipoint','hoverclick','mousemove','rclick','elementat','guardclick','raw','upload','pages','close')][string]$cmd,
  [string]$arg = '',
  [string]$arg2 = ''
)

$ErrorActionPreference = 'Stop'
$port = 9222

function Get-PageTarget {
  $list = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 10
  $pages = @($list | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl })
  if ($pages.Count -eq 0) { throw 'no page target' }
  # optional selection: -match <url substring> / -index <n>  (also via env for cross-process calls)
  $m = $arg2
  if (-not $m) { $m = $env:DY_TARGET_MATCH }
  if ($m) {
    $hit = @($pages | Where-Object { $_.url -like "*$m*" })
    if ($hit.Count -gt 0) { return $hit[0] }
  }
  $idx = 0
  if ($env:DY_TARGET_INDEX) { [void][int]::TryParse($env:DY_TARGET_INDEX, [ref]$idx) }
  if ($idx -gt 0 -and $idx -lt $pages.Count) { return $pages[$idx] }
  return $pages[0]
}

function New-CdpSession {
  param([string]$wsUrl)
  $ws = [System.Net.WebSockets.ClientWebSocket]::new()
  $ws.ConnectAsync([Uri]$wsUrl, [System.Threading.CancellationToken]::None).Wait()
  return $ws
}

$script:msgId = 0

function Send-Cdp {
  param($ws, [string]$method, $paramsObj)
  $script:msgId++
  $id = $script:msgId
  $payload = @{ id = $id; method = $method }
  if ($null -ne $paramsObj) { $payload['params'] = $paramsObj }
  $json = $payload | ConvertTo-Json -Depth 12 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).Wait()

  $buf = New-Object byte[] 262144
  $sb = New-Object System.Text.StringBuilder
  while ($true) {
    $res = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).Result
    [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
    if ($res.EndOfMessage) { break }
  }
  $obj = ($sb.ToString()) | ConvertFrom-Json
  while ($obj.id -ne $id) {
    [void]$sb.Clear()
    while ($true) {
      $res = $ws.ReceiveAsync([System.ArraySegment[byte]]::new($buf), [System.Threading.CancellationToken]::None).Result
      [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buf, 0, $res.Count))
      if ($res.EndOfMessage) { break }
    }
    $obj = ($sb.ToString()) | ConvertFrom-Json
  }
  return $obj
}

function Invoke-CdpEval {
  param($ws, [string]$expr)
  $r = Send-Cdp -ws $ws -method 'Runtime.evaluate' -paramsObj @{ expression = $expr; returnByValue = $true; awaitPromise = $true; userGesture = $true }
  if ($r.result.result.value -ne $null) { return [string]$r.result.result.value }
  if ($r.result.exceptionDetails) { return 'JS-EXCEPTION: ' + $r.result.exceptionDetails.text }
  return ''
}

function Invoke-Js {
  param($ws, [string]$expr)
  $r = Send-Cdp -ws $ws -method 'Runtime.evaluate' -paramsObj @{ expression = $expr; returnByValue = $true; awaitPromise = $true; userGesture = $true }
  if ($r.error) { return "CDP-ERROR: $($r.error.message)" }
  if ($r.result.exceptionDetails) { return "JS-EXCEPTION: $($r.result.exceptionDetails.text) $($r.result.exceptionDetails.exception.description)" }
  return $r.result.result.value
}

$t = Get-PageTarget
$ws = New-CdpSession -wsUrl $t.webSocketDebuggerUrl
try {
  switch ($cmd) {
    'targets' { $t | Select-Object id, type, title, url | ConvertTo-Json -Depth 5 }
    'title'   { "URL: $($t.url)"; "TITLE: $(Invoke-Js $ws 'document.title')" }
    'js'      { Invoke-Js $ws $arg }
    'nav' {
      [void](Send-Cdp -ws $ws -method 'Page.enable' -paramsObj @{})
      [void](Send-Cdp -ws $ws -method 'Page.navigate' -paramsObj @{ url = $arg })
      Start-Sleep -Seconds 6
      "navigated -> $(Invoke-Js $ws 'location.href')"
    }
    'click' {
      $expr = "(() => { const el = document.querySelector($($arg | ConvertTo-Json)); if(!el) return 'NOTFOUND'; el.scrollIntoView({block:'center'}); el.click(); return 'CLICKED'; })()"
      Invoke-Js $ws $expr
    }
    'type' {
      $expr = @"
(() => { const el = document.querySelector($($arg | ConvertTo-Json)); if(!el) return 'NOTFOUND'; el.focus();
  const proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
  setter.call(el, $($arg2 | ConvertTo-Json));
  try { el.setSelectionRange(el.value.length, el.value.length); } catch(e) {}
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  return 'TYPED:' + (el.value || '').length; })()
"@
      Invoke-Js $ws $expr
    }
    'shot' {
      $r = Send-Cdp -ws $ws -method 'Page.captureScreenshot' -paramsObj @{ format = 'png' }
      $path = if ($arg) { $arg } else { Join-Path $env:TEMP 'cdp_shot.png' }
      [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($r.result.data))
      "saved $path"
    }
    'hover' {
      $rect = Invoke-Js $ws "(()=>{const e=document.querySelector($($arg | ConvertTo-Json));if(!e)return '';const r=e.getBoundingClientRect();return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2})})()"
      if (-not $rect) { 'NOTFOUND' } else {
        $p = $rect | ConvertFrom-Json
        [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseMoved'; x = [double]$p.x; y = [double]$p.y; buttons = 0 })
        "hover $($p.x),$($p.y)"
      }
    }
    'iclick' {
      $rect = Invoke-Js $ws "(()=>{const e=document.querySelector($($arg | ConvertTo-Json));if(!e)return '';e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2})})()"
      if (-not $rect) { 'NOTFOUND' } else {
        $p = $rect | ConvertFrom-Json
        [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseMoved'; x = [double]$p.x; y = [double]$p.y })
        Start-Sleep -Milliseconds 120
        [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mousePressed'; x = [double]$p.x; y = [double]$p.y; button = 'left'; clickCount = 1 })
        Start-Sleep -Milliseconds 60
        [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseReleased'; x = [double]$p.x; y = [double]$p.y; button = 'left'; clickCount = 1 })
        "clicked $($p.x),$($p.y)"
      }
    }
    'itext' {
      [void](Send-Cdp -ws $ws -method 'Input.insertText' -paramsObj @{ text = $arg })
      "inserted $($arg.Length) chars"
    }
    'ipoint' {
      if ($env:DY_DRYRUN -eq '1') { "DRYRUN ipoint $arg"; break }
      $parts = $arg.Split(',')
      $x = [double]$parts[0]; $y = [double]$parts[1]
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseMoved'; x = $x; y = $y })
      Start-Sleep -Milliseconds 120
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mousePressed'; x = $x; y = $y; button = 'left'; clickCount = 1 })
      Start-Sleep -Milliseconds 70
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseReleased'; x = $x; y = $y; button = 'left'; clickCount = 1 })
      "clicked $x,$y"
    }
    'ikey' {
      $keyMap = @{ 'Enter' = @(13, 'Enter'); 'Escape' = @(27, 'Escape'); 'Backspace' = @(8, 'Backspace'); 'ArrowRight' = @(39, 'ArrowRight'); 'ArrowLeft' = @(37, 'ArrowLeft'); 'Space' = @(32, ' ') }
      if (-not $keyMap.ContainsKey($arg)) { "unsupported key $arg" } else {
        $k = $keyMap[$arg]
        [void](Send-Cdp -ws $ws -method 'Input.dispatchKeyEvent' -paramsObj @{ type = 'keyDown'; windowsVirtualKeyCode = $k[0]; key = $k[1] })
        [void](Send-Cdp -ws $ws -method 'Input.dispatchKeyEvent' -paramsObj @{ type = 'keyUp'; windowsVirtualKeyCode = $k[0]; key = $k[1] })
        "key $arg"
      }
    }
    'upload' {
      [void](Send-Cdp -ws $ws -method 'DOM.enable' -paramsObj @{})
      $doc = Send-Cdp -ws $ws -method 'DOM.getDocument' -paramsObj @{ depth = 1; pierce = $true }
      $q = Send-Cdp -ws $ws -method 'DOM.querySelector' -paramsObj @{ nodeId = $doc.result.root.nodeId; selector = $arg }
      if (-not $q.result.nodeId) { 'INPUT_NOT_FOUND' } else {
        $set = Send-Cdp -ws $ws -method 'DOM.setFileInputFiles' -paramsObj @{ nodeId = $q.result.nodeId; files = @($arg2) }
        if ($set.error) { "UPLOAD_ERR: $($set.error.message)" } else { "uploaded $arg2" }
      }
    }
    'pages' {
      (Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 10) |
        Where-Object { $_.type -eq 'page' } |
        ForEach-Object { $i = 0 } { $i++; [pscustomobject]@{ i = $i - 1; id = $_.id; url = $_.url; title = $_.title } } |
        ConvertTo-Json -Depth 4
    }
    'close' {
      # closes the currently selected target; returns closed=true|false
      try { Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/close/$($t.id)" -TimeoutSec 10 | Out-Null; 'closed=true' } catch { 'closed=false' }
    }    'hoverclick' {
      # hover first (reveals play button / card overlay), then a single real click
      $parts = $arg.Split(',')
      $x = [double]$parts[0]; $y = [double]$parts[1]
      $dwell = if ($arg2) { [int]$arg2 } else { 900 }
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseMoved'; x = $x; y = $y })
      Start-Sleep -Milliseconds $dwell
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mousePressed'; x = $x; y = $y; button = 'left'; clickCount = 1 })
      Start-Sleep -Milliseconds 80
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseReleased'; x = $x; y = $y; button = 'left'; clickCount = 1 })
      "hoverclicked $x,$y"
    }
    'mousemove' {
      $parts = $arg.Split(',')
      $x = [double]$parts[0]; $y = [double]$parts[1]
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseMoved'; x = $x; y = $y })
      "moved $x,$y"
    }
    'rclick' {
      # hover first so the bubble action bar shows up, then right-click for the context menu
      $parts = $arg.Split(',')
      $x = [double]$parts[0]; $y = [double]$parts[1]
      $dwell = if ($arg2) { [int]$arg2 } else { 500 }
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseMoved'; x = $x; y = $y })
      Start-Sleep -Milliseconds $dwell
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mousePressed'; x = $x; y = $y; button = 'right'; buttons = 2; clickCount = 1 })
      Start-Sleep -Milliseconds 90
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseReleased'; x = $x; y = $y; button = 'right'; buttons = 0; clickCount = 1 })
      "rclicked $x,$y"
    }
    'elementat' {
      # 诊断：坐标上到底是什么元素（是否 <a> 链接、链接去哪）
      $parts = $arg.Split(','); $x = [double]$parts[0]; $y = [double]$parts[1]
      $js = "(()=>{const e=document.elementFromPoint($x,$y);if(!e)return 'NO_ELEMENT';const a=e.closest('a');const r=e.getBoundingClientRect();return JSON.stringify({tag:e.tagName,txt:(e.innerText||'').replace(/\n/g,' ').slice(0,40),href:a?a.href:'',rect:[Math.round(r.x),Math.round(r.y),Math.round(r.width),Math.round(r.height)]})})()"
      (Invoke-CdpEval -ws $ws -expr $js)
    }
    'guardclick' {
      # 安全点击：先判断命中的是什么，命中“危险区”（别人主页/发布/充值/设置/删除）就拒绝
      $parts = $arg.Split(','); $x = [double]$parts[0]; $y = [double]$parts[1]
      if ($env:DY_DRYRUN -eq '1') { "DRYRUN guardclick $arg"; break }
      $js = "(()=>{const e=document.elementFromPoint($x,$y);if(!e)return JSON.stringify({ok:false,why:'NO_ELEMENT'});const a=e.closest('a');const href=a?a.href:'';const t=((e.innerText||'')+' '+(e.getAttribute('aria-label')||'')).replace(/\n/g,' ').trim().slice(0,40);return JSON.stringify({ok:true,tag:e.tagName,txt:t,href:href})})()"
      $info = (Invoke-CdpEval -ws $ws -expr $js)
      $bad = @('/user/', '/creator-micro/', '/publish', '充值', '投稿', '设置', '删除')
      $hit = $null; foreach ($b in $bad) { if ($info -like ('*' + $b + '*')) { $hit = $b; break } }
      if ($hit) { "MISCLICK_BLOCKED $hit :: $info"; break }
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseMoved'; x = $x; y = $y })
      Start-Sleep -Milliseconds 120
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mousePressed'; x = $x; y = $y; button = 'left'; buttons = 1; clickCount = 1 })
      Start-Sleep -Milliseconds 80
      [void](Send-Cdp -ws $ws -method 'Input.dispatchMouseEvent' -paramsObj @{ type = 'mouseReleased'; x = $x; y = $y; button = 'left'; buttons = 0; clickCount = 1 })
      "guarded-click $x,$y :: $info"
    }
    'raw' {
      $req = $arg | ConvertFrom-Json
      $prm = $null
      if ($req.PSObject.Properties.Name -contains 'params') { $prm = $req.params }
      (Send-Cdp -ws $ws -method $req.method -paramsObj $prm) | ConvertTo-Json -Depth 15 -Compress
    }
  }
}
finally {
  try { $ws.Dispose() } catch {}
}

