import { readFile, rm } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import {
  FileAttachmentValidationError,
  appendFileAttachmentContext,
  materializeFileAttachments,
  normalizeFileAttachments,
  stripFileAttachmentContext,
} from "./file-attachments.js";

describe("file attachments", () => {
  it("validates payloads and sanitizes file names", () => {
    const files = normalizeFileAttachments([
      {
        name: "../notes.txt",
        mimeType: "text/plain",
        base64: Buffer.from("hello").toString("base64"),
      },
    ]);

    expect(files).toEqual([
      {
        name: ".._notes.txt",
        mimeType: "text/plain",
        base64: "aGVsbG8=",
      },
    ]);
  });

  it("rejects malformed Base64 data", () => {
    expect(() =>
      normalizeFileAttachments([
        { name: "bad.txt", mimeType: "text/plain", base64: "%%%=" },
      ]),
    ).toThrow(FileAttachmentValidationError);
  });

  it("materializes files and appends readable paths", async () => {
    const [file] = await materializeFileAttachments(
      [
        {
          name: "notes.txt",
          mimeType: "text/plain",
          base64: Buffer.from("hello").toString("base64"),
        },
      ],
      "test-file",
    );

    try {
      expect(await readFile(file.path, "utf8")).toBe("hello");
      expect(appendFileAttachmentContext("Review this", [file])).toContain(
        `notes.txt: ${file.path}`,
      );
      expect(
        stripFileAttachmentContext(
          appendFileAttachmentContext("Review this", [file]),
        ),
      ).toBe("Review this");
    } finally {
      await rm(file.path, { force: true });
    }
  });
});
