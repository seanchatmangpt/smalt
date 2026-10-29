import type { Metadata } from "next";
import SwRegister from "../components/sw-register";
import "./globals.css";

export const metadata: Metadata = {
  title: "Smalt Sovereign Console",
  description:
    "Air-gapped Fortune-5 evaluation console for the smalt emulator. Zero external egress.",
  manifest: "/manifest.webmanifest",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className="antialiased">
        {children}
        <SwRegister />
      </body>
    </html>
  );
}
