import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const MAX_FILE_ATTACHMENTS = 5;
export const MAX_FILE_ATTACHMENT_BYTES = 10 * 1024 * 1024;

export interface FileAttachmentPayload {
  base64: string;
  name: string;
  mimeType: string;
}

export interface MaterializedFileAttachment {
  name: string;
  mimeType: string;
  path: string;
}

export class FileAttachmentValidationError extends Error {}

export function normalizeFileAttachments(
  value: unknown,
): FileAttachmentPayload[] {
  if (value == null) return [];
  if (!Array.isArray(value)) {
    throw new FileAttachmentValidationError("File attachments must be an array");
  }
  if (value.length > MAX_FILE_ATTACHMENTS) {
    throw new FileAttachmentValidationError(
      `A maximum of ${MAX_FILE_ATTACHMENTS} files can be attached`,
    );
  }

  return value.map((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new FileAttachmentValidationError("Invalid file attachment");
    }
    const attachment = item as Record<string, unknown>;
    if (typeof attachment.base64 !== "string") {
      throw new FileAttachmentValidationError("File attachment data is missing");
    }
    if (typeof attachment.name !== "string" || !attachment.name.trim()) {
      throw new FileAttachmentValidationError("File attachment name is missing");
    }
    if (
      attachment.base64.length >
      Math.ceil(MAX_FILE_ATTACHMENT_BYTES / 3) * 4 + 4
    ) {
      throw new FileAttachmentValidationError(
        `${attachment.name} exceeds the 10 MB file attachment limit`,
      );
    }

    const buffer = decodeBase64(attachment.base64, attachment.name);
    if (buffer.length > MAX_FILE_ATTACHMENT_BYTES) {
      throw new FileAttachmentValidationError(
        `${attachment.name} exceeds the 10 MB file attachment limit`,
      );
    }
    return {
      base64: attachment.base64,
      name: sanitizeAttachmentName(attachment.name),
      mimeType:
        typeof attachment.mimeType === "string" && attachment.mimeType.trim()
          ? attachment.mimeType.trim()
          : "application/octet-stream",
    };
  });
}

export async function materializeFileAttachments(
  files: FileAttachmentPayload[],
  prefix: string,
): Promise<MaterializedFileAttachment[]> {
  return Promise.all(
    files.map(async (file) => {
      const path = attachmentTempPath(prefix, file.name);
      await writeFile(path, decodeBase64(file.base64, file.name));
      return { name: file.name, mimeType: file.mimeType, path };
    }),
  );
}

export function materializeFileAttachmentsSync(
  files: FileAttachmentPayload[],
  prefix: string,
): MaterializedFileAttachment[] {
  return files.map((file) => {
    const path = attachmentTempPath(prefix, file.name);
    writeFileSync(path, decodeBase64(file.base64, file.name));
    return { name: file.name, mimeType: file.mimeType, path };
  });
}

export function appendFileAttachmentContext(
  text: string,
  files: MaterializedFileAttachment[],
): string {
  if (files.length === 0) return text;
  const paths = files.map((file) => `- ${file.name}: ${file.path}`).join("\n");
  return `${text}\n\n<ccpocket_file_attachments>\nRead these local files when needed:\n${paths}\n</ccpocket_file_attachments>`;
}

export function stripFileAttachmentContext(text: string): string {
  const marker = "\n\n<ccpocket_file_attachments>";
  const markerIndex = text.lastIndexOf(marker);
  if (
    markerIndex >= 0 &&
    text.endsWith("\n</ccpocket_file_attachments>")
  ) {
    return text.slice(0, markerIndex);
  }
  return text;
}

function sanitizeAttachmentName(name: string): string {
  const sanitized = name
    .replace(/[\\/\u0000-\u001f\u007f]/g, "_")
    .trim()
    .slice(0, 120);
  return sanitized || "attachment";
}

function attachmentTempPath(prefix: string, name: string): string {
  return join(tmpdir(), `ccpocket-${prefix}-${randomUUID()}-${name}`);
}

function decodeBase64(base64: string, name: string): Buffer {
  if (base64.length === 0) return Buffer.alloc(0);
  if (base64.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(base64)) {
    throw new FileAttachmentValidationError(`Invalid Base64 data for ${name}`);
  }
  const buffer = Buffer.from(base64, "base64");
  if (
    buffer.toString("base64").replace(/=+$/, "") !==
    base64.replace(/=+$/, "")
  ) {
    throw new FileAttachmentValidationError(`Invalid Base64 data for ${name}`);
  }
  return buffer;
}
