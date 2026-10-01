/// The SmallChat package version.
///
/// This is the one place the version is spelled. It is reported by
/// `smallchat --version`, the MCP server's and the channel server's
/// `serverInfo`, the MCP clients' `clientInfo`, and the `version` field of the
/// configs, toolkit files and knowledge bases SmallChat generates.
///
/// The compiled-artifact *format* version is separate: see
/// `ARTIFACT_FORMAT_VERSION` in SmallChatCore.
public enum SmallChatVersion {
    public static let current = "1.0.0"
}
