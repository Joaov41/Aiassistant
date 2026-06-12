import React, { useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  ArrowRight,
  Bot,
  Clipboard,
  Code2,
  FileText,
  Globe2,
  Image,
  Keyboard,
  LockKeyhole,
  MessageSquareText,
  PenLine,
  ScanSearch,
  Sparkles,
  WandSparkles,
} from "lucide-react";
import "./styles.css";

const quickActions = ["Summarize", "Key Points", "Simplify", "Translate"];

const attachments = [
  { label: "URL", icon: Globe2 },
  { label: "PDF", icon: FileText },
  { label: "Image", icon: Image },
  { label: "Text", icon: Clipboard },
];

const features = [
  {
    icon: ScanSearch,
    title: "Works in any app",
    body: "Select text, copy a link, or drop a file. AI Assistant brings context into one floating Mac window.",
  },
  {
    icon: WandSparkles,
    title: "Quick actions",
    body: "Run summaries, key points, simplification, translation, image description, and your own saved prompts.",
  },
  {
    icon: FileText,
    title: "Files and media",
    body: "Use PDFs, URLs, text files, EML messages, and images from the clipboard or drag and drop.",
  },
  {
    icon: LockKeyhole,
    title: "Private by design",
    body: "Use Apple Intelligence locally when available, or switch to Private Cloud Compute for larger jobs. Also private as per Apple's guidelines.",
  },
];

const workflow = [
  {
    icon: Keyboard,
    title: "Double or triple-tap Shift",
    body: "Double-tap Shift opens the assistant. Triple-tap Shift jumps straight into rewrite mode for selected text.",
  },
  {
    icon: PenLine,
    title: "Rewrite in place",
    body: "Improve selected text and send the finished version back into your current workflow.",
  },
  {
    icon: Bot,
    title: "Apple Intelligence",
    body: "Route requests through the on-device foundation model or Apple Private Cloud Compute.",
  },
  {
    icon: Code2,
    title: "Custom commands",
    body: "Save the prompts you repeat most and make them available as one-click actions.",
  },
];

const appScreenshots = [
  {
    src: "/screenshots/app-01.jpg",
    caption: "Ask questions and get a floating answer without leaving your current app.",
  },
  {
    src: "/screenshots/app-02.jpg",
    caption: "Choose any open app window to capture as context.",
  },
  {
    src: "/screenshots/app-03.jpg",
    caption: "Capture a window and ask what is on screen.",
  },
  {
    src: "/screenshots/app-04.jpg",
    caption: "Use image context for visual questions and descriptions.",
  },
  {
    src: "/screenshots/app-05.jpg",
    caption: "Summarize email content and extract key fields.",
  },
  {
    src: "/screenshots/app-06.jpg",
    caption: "Pull structured details from long EML messages.",
  },
  {
    src: "/screenshots/app-07.jpg",
    caption: "Ask questions about attached PDFs.",
  },
  {
    src: "/screenshots/app-08.jpg",
    caption: "Select an answer and ask a follow-up from that exact text.",
  },
  {
    src: "/screenshots/app-09.jpg",
    caption: "Run quick actions on selected text.",
  },
  {
    src: "/screenshots/app-10.jpg",
    caption: "Add custom prompts for repeated workflows.",
  },
];

function App() {
  const isFeaturesPage = window.location.pathname === "/features";

  return (
    <main className="site-shell">
      <BackgroundGrid />
      <Navigation current={isFeaturesPage ? "features" : "home"} />
      {isFeaturesPage ? <FeaturesPage /> : <HomePage />}
      <Footer />
    </main>
  );
}

function HomePage() {
  const [mode, setMode] = useState("chat");
  const [activeAction, setActiveAction] = useState("Summarize");
  const [sent, setSent] = useState(false);

  const response = useMemo(() => {
    if (activeAction === "Translate") {
      return "Turn messy context into clear, useful output without leaving the app you are already in.";
    }

    if (activeAction === "Simplify") {
      return "Turn messy context into clear, useful output without leaving the app you are already in.";
    }

    if (activeAction === "Key Points") {
      return "Turn messy context into clear, useful output without leaving the app you are already in.";
    }

    return "Turn messy context into clear, useful output without leaving the app you are already in.";
  }, [activeAction]);

  return (
    <>
      <section className="hero section" id="top">
        <div className="container hero-grid">
          <div className="hero-copy">
            <h1>
              <span className="headline-main">
                Apple Foundation models, ready wherever
              </span>
              <span className="headline-accent">you work.</span>
            </h1>
            <p>
              Summarize, rewrite, translate, inspect files, and ask follow-ups
              from any Mac app.
            </p>
            <div className="hero-actions">
              <a className="button primary" href="#download">
                Download <ArrowRight aria-hidden="true" size={18} />
              </a>
              <a className="button secondary" href="/features">
                See features
              </a>
            </div>
          </div>

          <AssistantMockup
            activeAction={activeAction}
            mode={mode}
            response={response}
            sent={sent}
            setActiveAction={setActiveAction}
            setMode={setMode}
            setSent={setSent}
          />
        </div>
      </section>

      <section className="section feature-band" id="features">
        <div className="container feature-grid">
          {features.map((feature) => (
            <FeatureCard key={feature.title} {...feature} />
          ))}
        </div>
      </section>

      <section className="section workflow" id="workflow">
        <div className="container workflow-grid">
          <div className="section-copy">
            <p>
              AI Assistant keeps the interface small and the context rich:
              selected text, clipboard content, files, images, and the previous
              conversation all stay within reach.
            </p>
          </div>
          <div className="workflow-list">
            {workflow.map((item, index) => (
              <WorkflowItem key={item.title} index={index + 1} {...item} />
            ))}
          </div>
        </div>
      </section>

      <section className="section privacy" id="privacy">
        <div className="container logo-showcase">
          <img src="/app-logo.png" alt="AI Assistant app logo" />
        </div>
      </section>
    </>
  );
}

function FeaturesPage() {
  return (
    <>
      <section className="screenshots-page section">
        <div className="container screenshots-heading">
          <h1>Features</h1>
        </div>
      </section>

      <section className="screenshot-gallery-section">
        <div className="container screenshot-gallery">
          {appScreenshots.map((screenshot, index) => (
            <figure className="screenshot-card glass-panel" key={screenshot.src}>
              <img
                src={screenshot.src}
                alt={`AI Assistant app screenshot ${index + 1}`}
                loading="eager"
              />
              <figcaption>{screenshot.caption}</figcaption>
            </figure>
          ))}
        </div>
      </section>
    </>
  );
}

function Navigation({ current }) {
  return (
    <nav className="nav" aria-label="Main navigation">
      <div className="container nav-inner">
        <a className="wordmark" href="/" aria-label="AI Assistant home">
          <span>[</span>AI Assistant<span>]</span>
        </a>
        <div className="nav-links">
          <a className={current === "features" ? "active" : ""} href="/features">
            Features
          </a>
          <a href="/#workflow">Workflow</a>
          <a href="/#privacy">Privacy</a>
          <a href="mailto:joao.valente@outlook.com">Contact</a>
          <a className="nav-cta" href="/#download">
            Download
          </a>
        </div>
      </div>
    </nav>
  );
}

function Footer() {
  return (
    <footer className="footer" id="download">
      <div className="container footer-inner">
        <p>[AI Assistant]</p>
        <a href="mailto:joao.valente@outlook.com">Contact</a>
      </div>
    </footer>
  );
}

function AssistantMockup({
  activeAction,
  mode,
  response,
  sent,
  setActiveAction,
  setMode,
  setSent,
}) {
  return (
    <div className="mockup-stage" aria-label="AI Assistant app preview">
      <div className="mockup-halo" />
      <div className="app-window glass-panel">
        <div className="window-bar">
          <div className="traffic-lights" aria-hidden="true">
            <span />
            <span />
            <span />
          </div>
          <span className="window-title">Assistant</span>
          <Sparkles size={17} aria-hidden="true" />
        </div>

        <div className="mode-switch" aria-label="Mode">
          <button
            className={mode === "chat" ? "selected" : ""}
            onClick={() => setMode("chat")}
            type="button"
          >
            <MessageSquareText size={15} aria-hidden="true" /> Chat
          </button>
          <button
            className={mode === "rewrite" ? "selected" : ""}
            onClick={() => setMode("rewrite")}
            type="button"
          >
            <PenLine size={15} aria-hidden="true" /> Rewrite
          </button>
        </div>

        <div className="context-row">
          {attachments.map(({ label, icon: Icon }) => (
            <span key={label}>
              <Icon size={14} aria-hidden="true" /> {label}
            </span>
          ))}
        </div>

        <div className="preview-card">
          <p className="preview-label">What it does</p>
          <h3>Apple Foundation Models across your Mac</h3>
          <p>
            Chat, rewrite in place, summarize URLs and PDFs, inspect images,
            translate text, and run your own custom prompts.
          </p>
        </div>

        <div className="action-grid">
          {quickActions.map((action) => (
            <button
              key={action}
              className={action === activeAction ? "active" : ""}
              onClick={() => {
                setActiveAction(action);
                setSent(false);
              }}
              type="button"
            >
              {action}
            </button>
          ))}
        </div>

        <div className="response-bubble">
          <div className="response-topline">
            <span>Your Mac, instantly smarter</span>
          </div>
          <p>{response}</p>
        </div>

        <form
          className="prompt-row"
          onSubmit={(event) => {
            event.preventDefault();
            setSent(true);
          }}
        >
          <input
            aria-label="Follow-up prompt"
            id="follow-up-prompt"
            name="follow-up-prompt"
            placeholder="Ask a follow-up..."
            type="text"
          />
          <button aria-label="Send follow-up" type="submit">
            <ArrowRight size={17} aria-hidden="true" />
          </button>
        </form>
      </div>
    </div>
  );
}

function FeatureCard({ icon: Icon, title, body }) {
  return (
    <article className="feature-card glass-panel">
      <Icon aria-hidden="true" size={28} />
      <h3>{title}</h3>
      <p>{body}</p>
    </article>
  );
}

function WorkflowItem({ icon: Icon, index, title, body }) {
  return (
    <article className="workflow-item">
      <div className="workflow-index">{String(index).padStart(2, "0")}</div>
      <div className="workflow-icon">
        <Icon aria-hidden="true" size={22} />
      </div>
      <div>
        <h3>{title}</h3>
        <p>{body}</p>
      </div>
    </article>
  );
}

function BackgroundGrid() {
  return (
    <div className="background" aria-hidden="true">
      <div className="grid" />
      <div className="beam beam-one" />
      <div className="beam beam-two" />
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);
