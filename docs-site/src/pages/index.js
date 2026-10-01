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
      "The LLM expresses intent. The runtime proposes at most one tool by vector similarity, and runs it only when its dispatch policy allows; otherwise it returns the candidates. No routing code. No tool selection prompts.",
    icon: "🎯",
  },
  {
    title: "Swift 6 Native",
    description:
      "Built in the Swift 6 language mode with actors and structured concurrency, so the compiler checks isolation and Sendable. Builds and tests on macOS and Linux; the libraries build for iOS.",
    icon: "🔷",
  },
  {
    title: "4-Phase Compiler",
    description:
      "Parse manifests, embed selectors, link dispatch tables, output artifacts. One command compiles your MCP config into a content-hashed artifact (@smallchat/core format 1.0) pinned to its embedder.",
    icon: "⚡",
  },
  {
    title: "MCP Server",
    description:
      "MCP server over Streamable HTTP (2025-11-25) that runs exactly the tool you call, with sessions, bearer-token auth, rate limiting, and an HMAC-chained audit log.",
    icon: "🌐",
  },
  {
    title: "Streaming & Inference",
    description:
      "Three-tier execution: token-level inference streaming, chunk-based streaming, and single-shot dispatch. Real-time UI feedback built in.",
    icon: "📡",
  },
  {
    title: "Guarded Dispatch",
    description:
      "One dispatch policy on every path, intent pinning, JSON Schema argument validation and opt-in semantic rate limiting. Each control is documented with where it stops.",
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
{`let runtime = try await MCPToolkit.load(source: "tools.toolkit.json").runtime
let resolution = try await runtime.resolve("find flights")   // runs nothing
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
    .package(url: "https://github.com/johnnyclem/smallchat-swift", from: "1.0.0"),
]`}
              </code>
            </pre>
            <p>
              Requires Swift 6.1+ on macOS 14+, Linux, or iOS 17+ (libraries).{" "}
              <Link to="/getting-started/installation">Full installation guide →</Link>
            </p>
          </div>
        </section>
      </main>
    </Layout>
  );
}
