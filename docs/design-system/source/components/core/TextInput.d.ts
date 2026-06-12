import * as React from "react";

export interface TextInputProps {
  multiline?: boolean;
  /** default = surface-variant fill + chartreuse focus; compose = surface fill + periwinkle focus. */
  tone?: "default" | "compose";
  value?: string;
  onChange?: (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => void;
  placeholder?: string;
  rows?: number;
  style?: React.CSSProperties;
  inputStyle?: React.CSSProperties;
}

/** Text field with an outline that turns the accent colour on focus. */
export declare function TextInput(props: TextInputProps): React.ReactElement;
