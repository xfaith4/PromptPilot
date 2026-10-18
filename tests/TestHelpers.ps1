function Start-PilotMockServer {
    param([object[]]$Responses = @(), [string]$Body = '', [int]$Status = 200)
    if (-not $Responses.Count) { $Responses = @(@{ Body = $Body; Status = $Status; DelayMs = 0 }) }
    $listener = $null
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $port = Get-Random -Minimum 20000 -Maximum 59000
        $candidate = [Net.HttpListener]::new()
        $candidate.Prefixes.Add("http://127.0.0.1:$port/")
        try { $candidate.Start(); $listener = $candidate; break } catch { $candidate.Close() }
    }
    if (-not $listener) { throw 'Could not start the loopback mock server.' }
    $requests = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    $worker = [Management.Automation.PowerShell]::Create()
    $null = $worker.AddScript({
        param($Listener, $Responses, $Requests)
        $index = 0
        while ($Listener.IsListening) {
            try {
                $context = $Listener.GetContext()
                $reader = [IO.StreamReader]::new($context.Request.InputStream, [Text.Encoding]::UTF8)
                try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $Requests.Enqueue(@{ Method = $context.Request.HttpMethod; Path = $context.Request.Url.PathAndQuery; Body = $body })
                $reply = $Responses[[Math]::Min($index, $Responses.Count - 1)]
                $index++
                if ($reply.DelayMs) { Start-Sleep -Milliseconds $reply.DelayMs }
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$reply.Body)
                $context.Response.StatusCode = [int]$reply.Status
                $context.Response.ContentType = 'application/json'
                $context.Response.Headers['request-id'] = 'req_mock'
                if ($reply.RetryAfter) { $context.Response.Headers['Retry-After'] = [string]$reply.RetryAfter }
                $context.Response.ContentLength64 = $bytes.Length
                $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $context.Response.Close()
            }
            catch { if (-not $Listener.IsListening) { break } }
        }
    }).AddArgument($listener).AddArgument($Responses).AddArgument($requests)
    $handle = $worker.BeginInvoke()
    return @{ Listener = $listener; Worker = $worker; Handle = $handle; Requests = $requests; Base = "http://127.0.0.1:$port" }
}

function Stop-PilotMockServer {
    param($Server)
    if ($Server) {
        try { $Server.Listener.Stop(); $Server.Listener.Close() } catch { }
        try { $Server.Worker.Stop(); $Server.Worker.Dispose() } catch { }
    }
}

function New-PilotMockProvider {
    param($Server, [string]$Name = 'Anthropic')
    $provider = (Get-PilotProviders)[$Name].Clone()
    $provider.ApiBase = $Server.Base
    $provider.ModelsUri = $Server.Base + '/models'
    return $provider
}

function New-PilotMockBudget {
    param([double]$Limit = 1)
    return New-PilotBudget -LimitUsd $Limit -Pricing @{ Known = $true; InputPerMillion = 1.0; OutputPerMillion = 2.0 }
}

function New-PilotMockOptions {
    return @{ Prompt = 'Fix the CSV parser. Preserve blank rows. Do not add dependencies.'; Context = ''; Goals = 'Keep every constraint.'; Model = 'claude-opus-5-5'; Iterations = 2; MaxOutputTokens = 512; BudgetUsd = 1; Profile = 'Coding task'; IncludeFile = $false; FilePath = ''; Pricing = @{ Known = $true; InputPerMillion = 1.0; OutputPerMillion = 2.0 } }
}
