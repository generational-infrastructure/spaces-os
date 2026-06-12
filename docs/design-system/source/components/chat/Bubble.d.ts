import * as React from "react";

export interface BubbleProps {
  /** me = right, on chartreuse; peer = left, on surface-variant. */
  from?: "me" | "peer";
  text?: string;
  /** Relative time label, e.g. "now", "2m". */
  time?: string;
  /** Delivery state for own messages: 🕓 pending → ✓ sent → ✓✓ read, ⚠ warn. */
  ack?: "pending" | "sent" | "read" | "warn";
  /** Assistant tokens/sec footer (peer bubbles). */
  tps?: number;
  /** Quoted-reply snippet shown above the text. */
  quote?: string;
  /** text (default) | notification (centered faded) | thinking (italic faded). */
  variant?: "text" | "notification" | "thinking";
  /** Show a streaming caret. */
  streaming?: boolean;
  searchHit?: boolean;
  searchCurrent?: boolean;
  style?: React.CSSProperties;
}

/** One chat row; alignment + fill encode the author. */
export declare function Bubble(props: BubbleProps): React.ReactElement;
