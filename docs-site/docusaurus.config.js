// @ts-check
import { themes as prismThemes } from "prism-react-renderer";

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "smallchat-swift",
  tagline: "Object-oriented inference. A native Swift tool compiler for the age of agents.",
  favicon: "img/favicon.ico",

  url: "https://smallchat.dev",
  baseUrl: "/swift/",

  organizationName: "johnnyclem",
  projectName: "smallchat-swift",

  onBrokenLinks: "throw",
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: "warn",
    },
  },

  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  presets: [
    [
      "classic",
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          sidebarPath: "./sidebars.js",
          editUrl: "https://github.com/johnnyclem/smallchat-swift/tree/main/docs-site/",
          routeBasePath: "/",
        },
        blog: false,
        theme: {
          customCss: "./src/css/custom.css",
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      image: "img/smallchat-swift-social.png",
      colorMode: {
        defaultMode: "dark",
        disableSwitch: false,
        respectPrefersColorScheme: true,
      },
      navbar: {
        title: "smallchat-swift",
        logo: {
          alt: "smallchat Logo",
          src: "img/logo.svg",
        },
        items: [
          {
            type: "docSidebar",
            sidebarId: "docs",
            position: "left",
            label: "Docs",
          },
          {
            to: "/api/tool-runtime",
            label: "API",
            position: "left",
          },
          {
            to: "/cli/commands",
            label: "CLI",
            position: "left",
          },
          {
            href: "https://smallchat.dev",
            label: "smallchat (TypeScript)",
            position: "right",
          },
          {
            href: "https://github.com/johnnyclem/smallchat-swift",
            label: "GitHub",
            position: "right",
          },
        ],
      },
      footer: {
        style: "dark",
        links: [
          {
            title: "Docs",
            items: [
              { label: "Getting Started", to: "/getting-started/installation" },
              { label: "Concepts", to: "/concepts/architecture" },
              { label: "Guides", to: "/guides/compilation" },
            ],
          },
          {
            title: "API Reference",
            items: [
              { label: "ToolRuntime", to: "/api/tool-runtime" },
              { label: "ToolCompiler", to: "/api/tool-compiler" },
              { label: "MCPServer", to: "/api/mcp-server" },
            ],
          },
          {
            title: "More",
            items: [
              {
                label: "GitHub",
                href: "https://github.com/johnnyclem/smallchat-swift",
              },
              {
                label: "smallchat (TypeScript)",
                href: "https://smallchat.dev",
              },
            ],
          },
        ],
        copyright: `Copyright ${new Date().getFullYear()} smallchat contributors. MIT License.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
        additionalLanguages: ["swift", "bash", "json"],
      },
      tableOfContents: {
        minHeadingLevel: 2,
        maxHeadingLevel: 4,
      },
    }),
};

export default config;
