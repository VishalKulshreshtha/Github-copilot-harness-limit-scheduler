# GitHub Copilot Harness Limit Scheduler Skill

Use this skill to run `GitHubCopilotHarnessResourceLimitDashboard.ps1` in scheduled-job mode from Copilot cowork/Scout.

## Purpose

Find newly created GitHub Copilot harness agents and Copilot Studio workflows, export an audit CSV, and apply a day-one message limit.

## Defaults

- `RunMode`: `ScheduledJob`
- `Range`: `Today`
- `LimitValue`: `0`
- `StopUsageAtLimit`: `true`
- `EnvironmentId`: blank, meaning all environments
- `AuditCsvPath`: `C:\Logs\github-copilot-harness-resource-limits.csv`

## Instruction for the assistant

When the user asks to run the GitHub Copilot harness limit scheduler:

1. Use the script path provided by the user, or default to:
   `C:\Users\vikulshr\OneDrive - Microsoft\Documents\Microsoft Scout\GitHubCopilotHarnessResourceLimitDashboard.ps1`
2. Use `-RunMode ScheduledJob`.
3. Use `-Range Today` unless the user asks for `Last7Days` or `Custom`.
4. Use `-LimitValue 0` unless the user provides another value.
5. Use `-StopUsageAtLimit $true` unless the user explicitly disables stop usage.
6. Leave `-EnvironmentId` out unless the user provides one.
7. Do not use `-EnablePvaBillingFallback` unless explicitly requested.
8. Run the command and report matched/updated counts plus the audit CSV path.

## Command template

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\GitHubCopilotHarnessResourceLimitDashboard.ps1" -RunMode ScheduledJob -Range Today -LimitValue 0 -StopUsageAtLimit $true -AuditCsvPath "C:\Logs\github-copilot-harness-resource-limits.csv"
```

For a custom date range, include:

```powershell
-Range Custom -StartDate "YYYY-MM-DD" -EndDate "YYYY-MM-DD"
```

For one environment, include:

```powershell
-EnvironmentId "<environment-id>"
```

