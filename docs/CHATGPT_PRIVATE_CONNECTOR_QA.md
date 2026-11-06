# Minyra private ChatGPT connector (development only)

This branch is an **experimental design / QA staging branch** and does not replace the stable Minyra application. The private connector source and Mac test package were delivered as an attachment in the ChatGPT conversation. They are **not merged or installed** here.

## Integration boundary
- The installed Minyra for Mac remains the native app, requiring explicit local approval for a requested coding task.
- A loopback-only MCP server offers 5 tools: get_status, list_projects, start_task, get_task_progress, get_result.
- The Swift UI app processes requests from owner-only files under `~/Library/Application Support/Minyra/ChatGPTBridge`.
- No separate arbitrary shell API, remote code execution endpoint or direct project file reading is provided.
- The app's own AgentCore, Seatbelt constraints, independent completion checks, and stop/recovery logic remain in place.
- Do **not** expose the unauthenticated local MCP port to the public Internet.

## Current validation boundary
- 8 offline Python transport tests pass.
- Swift addition passes syntax parsing, but it has **not** been compiled or executed on a physical Intel macOS 12 Mac.
- Current ChatGPT Plus does not provide full custom MCP write tools; publishing a Mac App Store app does not change connector permissions.
- No app publication, notarization, /Applications installation, live API acceptance, or ChatGPT plugin registration has occurred.

Before merging: review the companion package, run the Mac Xcode build and mock E2E checks, manually test authorization, verify security permissions, then open a tested source pull request.
