import React from "react";
import clsx from "clsx";
import Link from "@docusaurus/Link";
import useDocusaurusContext from "@docusaurus/useDocusaurusContext";
import Layout from "@theme/Layout";
import styles from "./index.module.css";

const features = [
  {
    title: "Semantic Dispatch",
    description:
      "The LLM expresses intent. The runtime resolves it — using vector similarity, resolution caching, and superclass traversal. No routing code. No tool selection prompts.",
    icon: "🎯",
  },
  {
    title: "Swift 6 Native",
    description:
      "Built with actors, structured concurrency, and Sendable types. Full thread safety with zero data races, leveraging the Swift type system.",
    icon: "🔷",
  },
  {
    title: "4-Phase Compiler",
    description:
      "Parse manifests, embed selectors, link dispatch tables, output artifacts. One command compiles your MCP config into an optimized dispatch table.",
    icon: "⚡",
  },
  {
    title: "MCP Server",
    description:
      "Production-ready MCP 2024-11-05 server with SSE, OAuth 2.1, rate limiting, session persistence, and audit logging.",
    icon: "🌐",
  },
  {
    title: "Streaming & Inference",
    description:
      "Three-tier execution: token-level inference streaming, chunk-based streaming, and single-shot dispatch. Real-time UI feedback built in.",
    icon: "📡",
  },
  {
    title: "Security First",
    description:
      "Intent pinning, selector namespacing, semantic rate limiting, type validation, and permission gating protect against adversarial inputs.",
    icon: "🔒",
  },
];

function Feature({ title, description, icon }) {
  return (
    <div className="feature-card">
      <div style={{ fontSize: "2rem", marginBottom: "0.5rem" }}>{icon}</div>
      <h3>{title}</h3>
      <p>{description}</p>
    </div>
  );
}

function HeroSection() {
  const { siteConfig } = useDocusaurusContext();
  return (
    <header className={clsx("hero", styles.heroBanner)}>
      <div className="container">
        <h1 className="hero__title">{siteConfig.title}</h1>
        <p className="hero__subtitle">{siteConfig.tagline}</p>
        <div className={styles.buttons}>
          <Link
            className="button button--primary button--lg"
            to="/getting-started/installation"
          >
            Get Started
          </Link>
          <Link
            className="button button--secondary button--lg"
            to="/concepts/architecture"
            style={{ marginLeft: "1rem" }}
          >
            How It Works
          </Link>
        </div>
        <div className={styles.codePreview}>
          <pre>
            <code>
{`let runtime = ToolRuntime(
    vectorIndex: MemoryVectorIndex(),
    embedder: LocalEmbedder()
)

let result = try await runtime.dispatch("find flights", args: ["to": "NYC"])`}
            </code>
          </pre>
        </div>
      </div>
    </header>
  );
}

export default function Home() {
  const { siteConfig } = useDocusaurusContext();
  return (
    <Layout
      title="Home"
      description={siteConfig.tagline}
    >
      <HeroSection />
      <main>
        <section className={styles.features}>
          <div className="container">
            <div className="features-grid">
              {features.map((props, idx) => (
                <Feature key={idx} {...props} />
              ))}
            </div>
          </div>
        </section>

        <section className={styles.quickInstall}>
          <div className="container">
            <h2>Quick Install</h2>
            <pre>
              <code>
{`// Package.swift
dependencies: [
    .package(url: "https://github.com/johnnyclem/smallchat-swift", from: "0.2.0"),
]`}
              </code>
            </pre>
            <p>
              Requires Swift 6.0+, macOS 14+, or iOS 17+.{" "}
              <Link to="/getting-started/installation">Full installation guide →</Link>
            </p>
          </div>
        </section>
      </main>
    </Layout>
  );
}
