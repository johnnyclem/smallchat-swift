/** @type {import('@docusaurus/plugin-content-docs').SidebarsConfig} */
const sidebars = {
  docs: [
    "intro",
    {
      type: "category",
      label: "Getting Started",
      collapsed: false,
      items: [
        "getting-started/installation",
        "getting-started/quick-start",
        "getting-started/first-dispatch",
      ],
    },
    {
      type: "category",
      label: "Concepts",
      items: [
        "concepts/architecture",
        "concepts/semantic-dispatch",
        "concepts/tool-classes",
        "concepts/selectors",
        "concepts/resolution-pipeline",
      ],
    },
    {
      type: "category",
      label: "Guides",
      items: [
        "guides/compilation",
        "guides/streaming",
        "guides/mcp-server",
        "guides/claude-code-integration",
        "guides/transport",
        "guides/security",
      ],
    },
    {
      type: "category",
      label: "CLI Reference",
      items: ["cli/commands"],
    },
    {
      type: "category",
      label: "API Reference",
      items: [
        "api/tool-runtime",
        "api/dispatch-builder",
        "api/tool-class",
        "api/tool-compiler",
        "api/embedding",
        "api/transport",
        "api/mcp-server",
        "api/channel-server",
      ],
    },
    {
      type: "category",
      label: "Modules",
      items: ["modules/overview"],
    },
  ],
};

export default sidebars;
