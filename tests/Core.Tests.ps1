BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:CorePath = Join-Path $script:Root 'PromptPilot.Core.ps1'
    . $script:CorePath
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:ClaudeResponse = '{"content":[{"type":"text","text":"Improved request. Preserve blank rows. Do not add dependencies."}],"usage":{"input_tokens":30,"output_tokens":20},"stop_reason":"end_turn"}'
    $script:OpenAIResponse = '{"choices":[{"message":{"content":"Working answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":10}}'
}

Describe 'Provider configuration and pricing' {
    It 'preserves JSON array scalars rather than serializing PowerShell wrapper properties' {
        $path = Join-Path $TestDrive 'array-scalars.json'
        [IO.File]::WriteAllText($path, '{"patterns":["alpha","(?i)Beta",3,true],"items":[{"id":"one"}]}')
        $value = Read-PilotJson $path
        $value.patterns[0] | Should -Be 'alpha'
        $value.patterns[1] | Should -Be '(?i)Beta'
        $value.patterns[2] | Should -Be 3
        $value.patterns[3] | Should -BeTrue
        $value.items[0].id | Should -Be one
    }
    It 'normalizes direct Anthropic and legacy GitHub identities without guessing versions' {
        Resolve-PilotModel Anthropic 'anthropic.claude-opus-5-5' | Should -Be 'claude-opus-5-5'
        Resolve-PilotProvider GitHubCopilot | Should -Be GitHubModels
        Resolve-PilotModel GitHubModels 'gpt-4.1' | Should -Be 'openai/gpt-4.1'
        { Resolve-PilotModel Anthropic 'us.anthropic.claude-opus-4-5-20251101-v1:0' } | Should -Throw '*Bedrock*'
    }
    It 'preserves saved keys and model while replacing incorrect shared legacy price defaults' {
        $path = Join-Path $TestDrive 'legacy.json'
        Write-PilotJson $path @{ ActiveProvider = 'Anthropic'; Keys = @{ Anthropic = 'ciphertext' }; Providers = @{ Anthropic = @{ Model = 'anthropic.claude-opus-5-5'; PricePer1kInputTokens = 0.00015; PricePer1kOutputTokens = 0.00060 }; GitHubCopilot = @{ Model = 'gpt-4.1' } } }
        $preferences = Read-PilotPreferences $path
        $preferences.Providers.Anthropic.Model | Should -Be 'claude-opus-5-5'
        $preferences.Keys.Anthropic | Should -Be 'ciphertext'
        $preferences.Providers.GitHubModels.Model | Should -Be 'openai/gpt-4.1'
        $preferences.PricingOverrides.Count | Should -Be 0
        (Get-PilotPricing Anthropic $preferences.Providers.Anthropic.Model).OutputPerMillion | Should -Be 20
        (Read-PilotJson $path).Providers.Anthropic.Model | Should -Be 'anthropic.claude-opus-5-5'
    }
    It 'migrates deliberate custom legacy rates using the correct 1K to 1M conversion' {
        $path = Join-Path $TestDrive 'custom.json'
        Write-PilotJson $path @{ ActiveProvider = 'OpenAI'; Providers = @{ OpenAI = @{ Model = 'my-model'; PricePer1kInputTokens = 0.001; PricePer1kOutputTokens = 0.003 } } }
        $preferences = Read-PilotPreferences $path
        $pricing = Get-PilotPricing OpenAI my-model $preferences.PricingOverrides
        $pricing.InputPerMillion | Should -Be 1
        $pricing.OutputPerMillion | Should -Be 3
        $pricing.IsCustom | Should -BeTrue
    }
    It 'keeps unknown rates unknown while supporting explicit free custom rates' {
        (Get-PilotPricing GitHubModels 'openai/gpt-4.1').Known | Should -BeFalse
        $rates = Get-PilotPricing GitHubModels 'openai/gpt-4.1' @{ 'GitHubModels/openai/gpt-4.1' = @{ InputPerMillion = 0; OutputPerMillion = 0 } }
        $rates.Known | Should -BeTrue
        $rates.OutputPerMillion | Should -Be 0
    }
    It 'rejects negative and non-finite pricing and malformed model IDs' {
        { Get-PilotPricing OpenAI custom @{ 'OpenAI/custom' = @{ InputPerMillion = -1; OutputPerMillion = 2 } } } | Should -Throw
        { Get-PilotPricing OpenAI custom @{ 'OpenAI/custom' = @{ InputPerMillion = [double]::NaN; OutputPerMillion = 2 } } } | Should -Throw
        { Resolve-PilotModel OpenAI 'model with spaces' } | Should -Throw
    }
    It 'recovers settings from an atomic backup without overwriting damaged data' {
        $path = Join-Path $TestDrive 'settings.json'
        $preferences = New-PilotPreferences
        Write-PilotJson $path $preferences
        $preferences.ActiveProvider = 'Anthropic'
        Write-PilotJson $path $preferences
        [IO.File]::WriteAllText($path, 'broken json')
        (Read-PilotPreferences $path).ActiveProvider | Should -Be OpenAI
        Get-Content -LiteralPath $path -Raw | Should -Be 'broken json'
    }
    It 'rejects future settings instead of silently losing their fields' {
        $path = Join-Path $TestDrive 'future.json'
        Write-PilotJson $path @{ SchemaVersion = 99 }
        { Read-PilotPreferences $path } | Should -Throw '*newer*'
    }
}

Describe 'Shared real HTTP request engine' {
    It 'uses Anthropic payload limits and combines only returned text blocks' {
        $server = Start-PilotMockServer -Body $script:ClaudeResponse
        try {
            $budget = New-PilotMockBudget
            $response = Invoke-PilotChat -Provider (New-PilotMockProvider $server) -ApiKey 'test-key' -Model 'anthropic.claude-opus-5-5' -System 'preserve intent' -Messages @(@{ role = 'user'; content = 'private prompt' }) -Budget $budget -MaxOutputTokens 512
            $response.Text | Should -Match 'Preserve blank rows'
            $request = $server.Requests.ToArray()[0]
            $request.Path | Should -Be '/v1/messages'
            $body = $request.Body | ConvertFrom-Json
            $body.model | Should -Be 'claude-opus-5-5'
            $body.max_tokens | Should -Be 512
            $body.system | Should -Be 'preserve intent'
            $budget.InputTokens | Should -Be 30
            [Math]::Abs($budget.ActualUsd - 0.00007) | Should -BeLessThan 0.00000001
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'caps OpenAI completion tokens and GitHub max tokens on their shared execution path' {
        foreach ($name in @('OpenAI', 'GitHubModels')) {
            $server = Start-PilotMockServer -Body $script:OpenAIResponse
            try {
                $model = if ($name -eq 'OpenAI') { 'gpt-5-mini' } else { 'openai/gpt-4.1' }
                $result = Invoke-PilotChat -Provider (New-PilotMockProvider $server $name) -ApiKey 'test-key' -Model $model -Messages @(@{ role = 'user'; content = 'test' }) -MaxOutputTokens 1024 -Budget (New-PilotMockBudget)
                $result.Text | Should -Be 'Working answer'
                $body = $server.Requests.ToArray()[0].Body | ConvertFrom-Json
                if ($name -eq 'OpenAI') { $body.max_completion_tokens | Should -Be 1024 }
                else { $body.max_tokens | Should -Be 1024 }
            }
            finally { Stop-PilotMockServer $server }
        }
    }
    It 'rejects a request before HTTP dispatch when it would exceed the budget' {
        $server = Start-PilotMockServer -Body $script:ClaudeResponse
        try {
            { Invoke-PilotChat -Provider (New-PilotMockProvider $server) -ApiKey 'test-key' -Model 'claude-opus-5-5' -Messages @(@{ role = 'user'; content = 'test' }) -Budget (New-PilotMockBudget 0.000001) } | Should -Throw '*budget reached*'
            $server.Requests.Count | Should -Be 0
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'retains fractional-dollar usage and refuses the next request when cumulative spend leaves insufficient room' {
        $server = Start-PilotMockServer -Body '{"content":[{"type":"text","text":"response"}],"usage":{"input_tokens":100,"output_tokens":500},"stop_reason":"end_turn"}'
        try {
            $budget = New-PilotMockBudget 0.002
            $arguments = @{ Provider = New-PilotMockProvider $server; ApiKey = 'test-key'; Model = 'claude-opus-5-5'; Messages = @(@{ role = 'user'; content = 'test' }); Budget = $budget; MaxOutputTokens = 512 }
            $null = Invoke-PilotChat @arguments
            [Math]::Abs($budget.UsedUsd - 0.0011) | Should -BeLessThan 0.00000001
            { Invoke-PilotChat @arguments } | Should -Throw '*budget reached*'
            $server.Requests.Count | Should -Be 1
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'logs actionable 404 metadata and redacts provider-echoed credentials without retrying' {
        $server = Start-PilotMockServer -Status 404 -Body '{"error":{"type":"not_found_error","message":"model unknown; test-key"}}'
        $events = [Collections.Concurrent.ConcurrentQueue[object]]::new()
        try {
            { Invoke-PilotChat -Provider (New-PilotMockProvider $server) -ApiKey 'test-key' -Model 'missing-model' -Messages @(@{ role = 'user'; content = 'private prompt' }) -Budget (New-PilotMockBudget) -Events $events } | Should -Throw '*HTTP 404*'
            $server.Requests.Count | Should -Be 1
            $messages = $events.ToArray().Message -join "`n"
            $messages | Should -Match 'not_found_error|request-id=req_mock'
            $messages | Should -Match '\[REDACTED\]'
            $messages | Should -Not -Match 'test-key|private prompt'
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'retries a 503 and then returns the successful response through the same engine' {
        $server = Start-PilotMockServer -Responses @(@{ Status = 503; Body = '{"error":{"message":"temporary"}}' }, @{ Status = 200; Body = $script:ClaudeResponse })
        try {
            $result = Invoke-PilotChat -Provider (New-PilotMockProvider $server) -ApiKey 'test-key' -Model 'claude-opus-5-5' -Messages @(@{ role = 'user'; content = 'test' }) -Budget (New-PilotMockBudget) -RetryDelayMs 1
            $result.Text | Should -Match 'Improved request'
            $server.Requests.Count | Should -Be 2
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'retains possible server-error spending and does not dispatch a retry past the run ceiling' {
        $server = Start-PilotMockServer -Status 503 -Body '{"error":{"message":"server failed after request receipt"}}'
        try {
            $provider = New-PilotMockProvider $server
            $price = (New-PilotMockBudget).Pricing
            $messages = @(@{ role = 'user'; content = 'test' })
            $body = New-PilotChatJson $provider claude-opus-5-5 '' $messages 512
            $ceiling = Get-PilotCallCeiling $body 512 $price
            $budget = New-PilotBudget -LimitUsd ($ceiling * 1.5) -Pricing $price
            { Invoke-PilotChat -Provider $provider -ApiKey test-key -Model claude-opus-5-5 -Messages $messages -MaxOutputTokens 512 -Budget $budget -RetryDelayMs 1 } | Should -Throw '*budget reached*'
            $budget.UsedUsd | Should -BeGreaterThan 0
            $server.Requests.Count | Should -Be 1
        } finally { Stop-PilotMockServer $server }
    }
    It 'honors Retry-After and does not retry early when the provider requests a long delay' {
        $server = Start-PilotMockServer -Responses @(@{ Status = 429; Body = '{"error":{"message":"rate limited"}}'; RetryAfter = 1 }, @{ Status = 200; Body = $script:ClaudeResponse })
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $null = Invoke-PilotChat -Provider (New-PilotMockProvider $server) -ApiKey 'test-key' -Model 'claude-opus-5-5' -Messages @(@{ role = 'user'; content = 'test' }) -Budget (New-PilotMockBudget) -RetryDelayMs 1
            $watch.ElapsedMilliseconds | Should -BeGreaterOrEqual 850
            $server.Requests.Count | Should -Be 2
        }
        finally { Stop-PilotMockServer $server }
        $server = Start-PilotMockServer -Responses @(@{ Status = 429; Body = '{"error":{"message":"rate limited"}}'; RetryAfter = 120 })
        try {
            { Invoke-PilotChat -Provider (New-PilotMockProvider $server) -ApiKey 'test-key' -Model 'claude-opus-5-5' -Messages @(@{ role = 'user'; content = 'test' }) -Budget (New-PilotMockBudget) } | Should -Throw '*Wait before trying again*'
            $server.Requests.Count | Should -Be 1
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'keeps missing usage unknown and retains a conservative budget reservation' {
        $server = Start-PilotMockServer -Body '{"content":[{"type":"text","text":"response"}],"stop_reason":"end_turn"}'
        try {
            $budget = New-PilotMockBudget
            $response = Invoke-PilotChat -Provider (New-PilotMockProvider $server) -ApiKey 'test-key' -Model 'claude-opus-5-5' -Messages @(@{ role = 'user'; content = 'test' }) -Budget $budget
            $response.CostUsd | Should -BeNullOrEmpty
            $budget.UsageComplete | Should -BeFalse
            $budget.UsedUsd | Should -BeGreaterThan 0
            $options = New-PilotMockOptions
            $options.Iterations = 1
            $workflow = Invoke-PilotWorkflow Refine $options (New-PilotMockProvider $server) 'test-key'
            $workflow.Usage.InputTokens | Should -BeNullOrEmpty
            $workflow.Usage.OutputTokens | Should -BeNullOrEmpty
            $workflow.Usage.CostUsd | Should -BeNullOrEmpty
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'reports exhausted reasoning/output tokens without pretending empty text is success' {
        $server = Start-PilotMockServer -Body '{"content":[],"usage":{"input_tokens":10,"output_tokens":512},"stop_reason":"max_tokens"}'
        try {
            { Invoke-PilotChat -Provider (New-PilotMockProvider $server) -ApiKey 'test-key' -Model 'claude-opus-5-5' -Messages @(@{ role = 'user'; content = 'test' }) -Budget (New-PilotMockBudget) } | Should -Throw '*reasoning tokens*'
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'discovers paginated Claude model IDs and a root-array GitHub catalog' {
        $server = Start-PilotMockServer -Responses @(@{ Status = 200; Body = '{"data":[{"id":"claude-one"}],"has_more":true,"last_id":"one"}' }, @{ Status = 200; Body = '{"data":[{"id":"claude-two"}],"has_more":false}' })
        try {
            $models = @(Get-PilotModels -Provider (New-PilotMockProvider $server) -ApiKey 'test-key')
            $models.Id | Should -Be @('claude-one', 'claude-two')
            $server.Requests.ToArray()[1].Path | Should -Match 'after_id=one'
        }
        finally { Stop-PilotMockServer $server }
        $server = Start-PilotMockServer -Body '[{"id":"openai/gpt-4.1","name":"GPT-4.1"}]'
        try { @(Get-PilotModels -Provider (New-PilotMockProvider $server GitHubModels) -ApiKey 'test-key')[0].Id | Should -Be 'openai/gpt-4.1' }
        finally { Stop-PilotMockServer $server }
    }
    It 'rejects non-HTTPS endpoints outside loopback and does not persist raw error pages' {
        { Invoke-PilotHttp -Provider (Get-PilotProviders).OpenAI -ApiKey 'test-key' -Uri 'http://example.com/chat' } | Should -Throw '*HTTPS*'
        $server = Start-PilotMockServer -Status 403 -Body '<html>private raw page</html>'
        try {
            { Invoke-PilotHttp -Provider (New-PilotMockProvider $server) -ApiKey 'test-key' -Uri ($server.Base + '/chat') } | Should -Throw '*HTTP 403*'
        }
        finally { Stop-PilotMockServer $server }
    }
}

Describe 'Real workflow state and cancellation' {
    It 'refines using the original authoritative request in every iteration and publishes completed revisions' {
        $server = Start-PilotMockServer -Body $script:ClaudeResponse
        $events = [Collections.Concurrent.ConcurrentQueue[object]]::new()
        try {
            $options = New-PilotMockOptions
            $result = Invoke-PilotWorkflow Refine $options (New-PilotMockProvider $server) 'test-key' $events
            $result.Status | Should -Be Completed
            $result.Revisions.Count | Should -Be 2
            @($events.ToArray() | Where-Object Kind -eq Revision).Count | Should -Be 2
            foreach ($request in $server.Requests.ToArray()) {
                $body = $request.Body | ConvertFrom-Json
                $body.messages[0].content | Should -Match ([regex]::Escape($options.Prompt))
                $body.system | Should -Match 'Do not assume PowerShell'
            }
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'preserves a completed revision when the next request fails' {
        $server = Start-PilotMockServer -Responses @(@{ Status = 200; Body = $script:ClaudeResponse }, @{ Status = 400; Body = '{"error":{"message":"bad next request"}}' })
        try {
            $result = Invoke-PilotWorkflow Refine (New-PilotMockOptions) (New-PilotMockProvider $server) 'test-key'
            $result.Status | Should -Be Failed
            $result.Revisions.Count | Should -Be 1
            $result.OutputText | Should -Match 'Preserve blank rows'
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'cancels an active request promptly without waiting for the HTTP timeout' {
        $server = Start-PilotMockServer -Responses @(@{ Status = 200; Body = $script:ClaudeResponse; DelayMs = 15000 })
        $cts = [Threading.CancellationTokenSource]::new()
        $worker = [Management.Automation.PowerShell]::Create()
        try {
            $null = $worker.AddScript({ param($Core, $Options, $Provider, $Token) . $Core; Invoke-PilotWorkflow Refine $Options $Provider 'test-key' $null $Token }).AddArgument($script:CorePath).AddArgument((New-PilotMockOptions)).AddArgument((New-PilotMockProvider $server)).AddArgument($cts.Token)
            $handle = $worker.BeginInvoke()
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while ($server.Requests.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            $server.Requests.Count | Should -Be 1
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $cts.Cancel()
            $handle.AsyncWaitHandle.WaitOne(3000) | Should -BeTrue
            $result = @($worker.EndInvoke($handle))[-1]
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 3
            $result.Status | Should -Be Cancelled
        }
        finally { $worker.Dispose(); $cts.Dispose(); Stop-PilotMockServer $server }
    }
    It 'validates actual connection-test generation rather than model metadata alone' {
        $server = Start-PilotMockServer -Body '{"content":[{"type":"text","text":"PROMPT_PILOT_OK"}],"usage":{"input_tokens":10,"output_tokens":5}}'
        try {
            $result = Invoke-PilotWorkflow Test (New-PilotMockOptions) (New-PilotMockProvider $server) 'test-key'
            $result.Status | Should -Be Completed
            ($server.Requests.ToArray()[0].Body | ConvertFrom-Json).messages[0].content | Should -Match 'PROMPT_PILOT_OK'
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'keeps truncated output and stops further iterations' {
        $server = Start-PilotMockServer -Body '{"content":[{"type":"text","text":"partial draft"}],"usage":{"input_tokens":10,"output_tokens":512},"stop_reason":"max_tokens"}'
        try {
            $result = Invoke-PilotWorkflow Refine (New-PilotMockOptions) (New-PilotMockProvider $server) 'test-key'
            $result.Status | Should -Be OutputLimit
            $result.OutputText | Should -Be 'partial draft'
            $server.Requests.Count | Should -Be 1
        }
        finally { Stop-PilotMockServer $server }
    }
    It 'bounds iterations and combined input before a request is sent' {
        $options = New-PilotMockOptions
        $options.Iterations = 999
        (Invoke-PilotWorkflow Refine $options (Get-PilotProviders).Anthropic 'test-key').Error | Should -Match '1 and 5'
        $options.Iterations = 1
        $options.Prompt = 'a' * 64001
        (Invoke-PilotWorkflow Refine $options (Get-PilotProviders).Anthropic 'test-key').Error | Should -Match '64,000'
    }
}

Describe 'Local documents, session recovery and comparison' {
    It 'includes supported UTF-8/Unicode text with explicit truncation metadata' {
        $path = Join-Path $TestDrive 'context.md'
        [IO.File]::WriteAllText($path, ('abc' * 100), [Text.UTF8Encoding]::new($false))
        $file = Read-PilotAttachment $path -MaxCharacters 50
        $file.IncludedCharacters | Should -Be 50
        $file.OriginalCharacters | Should -Be 300
        $file.Truncated | Should -BeTrue
    }
    It 'rejects unsupported extensions, oversized documents and binary text' {
        $path = Join-Path $TestDrive 'image.png'
        [IO.File]::WriteAllText($path, 'fake image')
        { Read-PilotAttachment $path } | Should -Throw '*supported text*'
        $path = Join-Path $TestDrive 'binary.txt'
        [IO.File]::WriteAllBytes($path, [byte[]]@(65, 0, 66))
        { Read-PilotAttachment $path } | Should -Throw '*binary*'
        [IO.File]::WriteAllText($path, ('x' * 100))
        { Read-PilotAttachment $path -MaxBytes 50 } | Should -Throw '*larger*'
    }
    It 'round-trips full sessions and recovers the previous valid autosave after corruption' {
        $session = New-PilotSession Anthropic claude-opus-5-5
        $session.BasePrompt = 'Original request'
        $session.Answer = 'Answer text'
        $session.FinalPrompt = 'Refined prompt'
        $session.Revisions = @(@{ Number = 1; Text = 'Refined prompt'; Model = 'claude-opus-5-5'; AtUtc = [DateTime]::UtcNow.ToString('o') })
        $path = Join-Path $TestDrive 'session.json'
        Save-PilotSession $path $session
        $session.Answer = 'Changed answer'
        Save-PilotSession $path $session
        (Read-PilotSession $path).Answer | Should -Be 'Changed answer'
        [IO.File]::WriteAllText($path, '{broken')
        $recovered = Read-PilotSession $path
        $recovered.BasePrompt | Should -Be 'Original request'
        $recovered.Answer | Should -Be 'Answer text'
        $recovered.Revisions.Count | Should -Be 1
        $recovered.Revisions[0].Text | Should -Be 'Refined prompt'
    }
    It 'filters credentials and arbitrary fields out of sessions, revisions, usage and Markdown exports' {
        $session = New-PilotSession
        $session.BasePrompt = 'safe prompt'
        $session.ApiKey = 'SECRET_VALUE'
        $session.Revisions = @(@{ Number = 1; Text = 'safe draft'; ApiKey = 'SECRET_VALUE' })
        $session.Usage = @{ InputTokens = 10; ApiKey = 'SECRET_VALUE' }
        $path = Join-Path $TestDrive 'safe.json'
        Save-PilotSession $path $session
        Get-Content -LiteralPath $path -Raw | Should -Not -Match 'SECRET_VALUE|ApiKey'
        Export-PilotMarkdown $session | Should -Not -Match 'SECRET_VALUE'
    }
    It 'rejects session traversal IDs, future schemas and invalid budgets' {
        $session = New-PilotSession
        $session.Id = '../outside'
        { ConvertTo-PilotSession $session } | Should -Throw '*ID*'
        $session = New-PilotSession
        $session.BudgetUsd = [double]::NaN
        { ConvertTo-PilotSession $session } | Should -Throw '*budget*'
        $session = New-PilotSession
        $session.IncludeFile = 'false'
        { ConvertTo-PilotSession $session } | Should -Throw '*boolean*'
    }
    It 'produces a comparison that reconstructs both original and revised documents' {
        $left = "one`ntwo`nthree"
        $right = "one`nnew`nthree`nfour"
        $diff = @(Compare-PilotText $left $right)
        (@($diff | Where-Object Kind -ne Added).Text -join "`n") | Should -Be $left
        (@($diff | Where-Object Kind -ne Removed).Text -join "`n") | Should -Be $right
    }
}
