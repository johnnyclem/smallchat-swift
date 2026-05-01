import ArgumentParser

@main
struct SmallChatCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "smallchat",
        abstract: "A message-passing tool compiler inspired by the Smalltalk/Objective-C runtime",
        discussion: """
        Getting Started
        ───────────────
          1. Set up your environment (auto-detects your MCP servers):
             $ smallchat setup

          2. Or compile manually from an MCP config file:
             $ smallchat compile --source ~/.mcp.json

          3. Inspect your compiled toolkit:
             $ smallchat inspect tools.toolkit.json

          4. Test dispatch resolution:
             $ smallchat resolve tools.toolkit.json "search for files"

          5. Start a server:
             $ smallchat serve --source tools.toolkit.json

          Run "smallchat <command> --help" for detailed usage of any command.
          Run "smallchat doctor" to check your system health.
        """,
        version: "0.2.0",
        subcommands: [
            CompileCommand.self,
            ServeCommand.self,
            ChannelCommand.self,
            ResolveCommand.self,
            InspectCommand.self,
            InitCommand.self,
            ReplCommand.self,
            DocsCommand.self,
            DoctorCommand.self,
            SetupCommand.self,
            DreamCommand.self,
            InstallCommand.self,
        ]
    )
}
