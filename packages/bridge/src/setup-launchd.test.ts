import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

const mockExecSync = vi.fn();
vi.mock("node:child_process", () => ({
  execSync: (...args: unknown[]) => mockExecSync(...args),
}));

const mockExistsSync = vi.fn();
const mockMkdirSync = vi.fn();
const mockWriteFileSync = vi.fn();
const mockUnlinkSync = vi.fn();
vi.mock("node:fs", () => ({
  existsSync: (...args: unknown[]) => mockExistsSync(...args),
  mkdirSync: (...args: unknown[]) => mockMkdirSync(...args),
  writeFileSync: (...args: unknown[]) => mockWriteFileSync(...args),
  unlinkSync: (...args: unknown[]) => mockUnlinkSync(...args),
}));

vi.mock("node:os", () => ({
  homedir: () => "/Users/testuser",
}));

const { setupLaunchd, uninstallLaunchd } = await import("./setup-launchd.js");

const PLIST_PATH = "/Users/testuser/Library/LaunchAgents/com.ccpocket.bridge.plist";

describe("setup-launchd", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue("/usr/bin/npx\n");
  });

  afterEach(() => {
    delete process.env.BRIDGE_PUBLIC_WS_URL;
  });

  describe("setupLaunchd", () => {
    it("writes correct plist with default options", () => {
      setupLaunchd({});

      expect(mockWriteFileSync).toHaveBeenCalledOnce();
      const [path, content] = mockWriteFileSync.mock.calls[0] as [string, string];
      expect(path).toBe(PLIST_PATH);
      expect(content).toContain("<key>BRIDGE_PORT</key>");
      expect(content).toContain("<string>8765</string>");
      expect(content).toContain("<key>BRIDGE_HOST</key>");
      expect(content).not.toContain("BRIDGE_API_KEY");
      expect(content).not.toContain("BRIDGE_PUBLIC_WS_URL");
    });

    it("includes BRIDGE_PUBLIC_WS_URL when publicWsUrl is provided", () => {
      setupLaunchd({ publicWsUrl: "wss://example.com/ws" });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<key>BRIDGE_PUBLIC_WS_URL</key>");
      expect(content).toContain("<string>wss://example.com/ws</string>");
    });

    it("prefers explicit publicWsUrl over environment", () => {
      process.env.BRIDGE_PUBLIC_WS_URL = "wss://env.example.com";

      setupLaunchd({ publicWsUrl: "wss://flag.example.com" });

      const content = mockWriteFileSync.mock.calls[0]![1] as string;
      expect(content).toContain("<string>wss://flag.example.com</string>");
      expect(content).not.toContain("wss://env.example.com");
    });
  });

  describe("uninstallLaunchd", () => {
    it("deletes plist when it exists", () => {
      mockExistsSync.mockReturnValue(true);

      uninstallLaunchd();

      expect(mockUnlinkSync).toHaveBeenCalledWith(PLIST_PATH);
    });
  });
});
