import * as React from "react";
import type { DotStatus } from "./StatusDot";

export interface MachineChipProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** Hostname / nickname (rendered in mono). */
  name: string;
  /** The machine's STABLE accent colour — reuse it everywhere for this machine. */
  color?: string;
  /** Live reachability/activity; shows a leading StatusDot when set. */
  status?: DotStatus;
  /** Reached off-LAN through the relay rather than direct. */
  relayed?: boolean;
  size?: "sm" | "md";
  /** outline (default) · ghost · solid (filled — for the active selection). */
  variant?: "outline" | "ghost" | "solid";
}

/**
 * Identity chip for an executor ("machine"): colour = which machine,
 * StatusDot = reachability. The cornerstone of the multi-executor UX.
 */
export declare function MachineChip(props: MachineChipProps): React.ReactElement;
