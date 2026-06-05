# マルチ Bridge 接続 & 分割ペイン設計

## 調査日 / 対象

- 調査日: 2026-06-05
- 対象プラットフォーム: **macOS / デスクトップ中心**（モバイルは従来の単一表示を維持）
- ゴール: **tmux 的に自由分割したペインのそれぞれに、同時接続した任意マシン（bridge）の任意セッションを置ける**

---

## 1. 背景・ゴール

現状アプリは「1台の bridge にだけ繋ぎ、1つのセッションを表示」する作り。デスクトップで使う際に以下をやりたい:

1. **複数 bridge への同時接続** — 例: Mac の bridge と Windows の bridge に同時に繋ぎ、両方のセッションを並行して扱う。
2. **tmux 的なウィンドウ分割** — 画面を縦横自由に分割し、各ペインに独立したセッションを表示する。

最終形は「**任意のペイン = 任意マシンの任意セッション**」。2 は 1 を前提に組むと自然に合流する。

### 非ゴール（初期スコープ外）

- モバイル（iPhone/iPad）での分割 UI（狭画面向けの作り込みは後回し。モバイルは single 維持）
- ペイン間でのセッション「移動」アニメーション等の凝った UX（Phase 4 で検討）
- bridge 側プロトコルの破壊的変更（接続は今のまま N 本張る方式）

---

## 2. 現状アーキテクチャ

### 2.1 接続は単一インスタンス

- `BridgeService` は **シングルトン**。`main.dart` で 1 個だけ生成し、`RepositoryProvider<BridgeService>.value` でアプリ全体に供給している。
  - [`apps/mobile/lib/main.dart:192`](../apps/mobile/lib/main.dart#L192) `final bridge = BridgeService();`
  - [`apps/mobile/lib/main.dart:213`](../apps/mobile/lib/main.dart#L213) `RepositoryProvider<BridgeService>.value(value: bridge)`
- `BridgeService` は内部に **WebSocket 1 本** (`WebSocketChannel? _channel`) を持ち、`connect(url)` は既存接続を閉じて 1 本に繋ぎ直す。
  - [`apps/mobile/lib/services/bridge_service.dart:27`](../apps/mobile/lib/services/bridge_service.dart#L27) `WebSocketChannel? _channel;`
  - [`apps/mobile/lib/services/bridge_service.dart:230`](../apps/mobile/lib/services/bridge_service.dart#L230) `void connect(String url)`
- `MachineManagerService` は保存済みマシンの **一覧・状態・切り替え** を管理するだけで、**並列接続はしない**（アクティブは常に 1 台）。
  - [`apps/mobile/lib/services/machine_manager_service.dart`](../apps/mobile/lib/services/machine_manager_service.dart)

### 2.2 横断 Cubit が単一 bridge のストリームに直結

`main.dart` で以下の Cubit が **唯一の bridge のストリーム**から生成されている。複数接続化するとこれらは「接続ごと」に分裂する必要がある:

| Cubit | ソース | 複数接続時の扱い |
|-------|--------|----------------|
| `ConnectionCubit` | `bridge.connectionState` | 接続ごと |
| `ActiveSessionsCubit` | `bridge.sessionList` | 接続ごと（集約ビューは別途） |
| `RecentSessionsCubit` | `bridge.recentSessions` | 接続ごと |
| `GalleryCubit` | `bridge.galleryStream` | 接続ごと |
| `FileListCubit` | `bridge.fileList` | 接続ごと（= ペインスコープ） |

参照: [`apps/mobile/lib/main.dart:236-257`](../apps/mobile/lib/main.dart#L236-L257)

### 2.3 セッション識別子は `sessionId` 単独

セッション画面は `sessionId` / `projectPath` 等を受け取るが、「どの接続のセッションか」という概念がない。

- [`apps/mobile/lib/features/claude_session/claude_session_screen.dart:72`](../apps/mobile/lib/features/claude_session/claude_session_screen.dart#L72)

> ⚠️ メモ: bridge は session イベントを**全クライアントにブロードキャスト**し、クライアント側が `sessionId` でフィルタする設計（混線トラップ）。複数接続では各 `BridgeService` が**別ソケット**なので、接続単位では自然に分離される。ただし「同一 bridge に複数接続を張る」ことは避ける（接続は bridge ごとに 1 本）。

### 2.4 レイアウトは幅依存の自動切替

- `_WorkspaceLayoutMode { single, doublePane, triplePane }` を**ウィンドウ幅のブレークポイント**で自動選択。ユーザー操作の分割ではない。
  - [`apps/mobile/lib/features/session_list/workspace_shell_screen.dart:31`](../apps/mobile/lib/features/session_list/workspace_shell_screen.dart#L31)
  - [`apps/mobile/lib/features/session_list/workspace_shell_screen.dart:72`](../apps/mobile/lib/features/session_list/workspace_shell_screen.dart#L72)
- 構成は「ナビ + **1 つのセッション** + ツールペイン(Explore/Git/Gallery)」。複数セッションを並べる作りではない。
- 可動仕切りは既にある: `_WorkspaceResizeDivider`（流用可能）。
- macOS タブ (`TabsCubit` / `TabEntry`) で複数セッションを保持できるが、表示は 1 つずつ。

---

## 3. 設計

### 鍵となる方針（最小改修で最大効果）

セッション画面群は `context.read<BridgeService>()` で接続を掴んでいる。
**各分割ペインのサブツリーに、そのペイン専用の `BridgeService`（＋派生 Cubit 群）を inject する**ことで、
**セッション画面のロジックはほぼ無改修**のまま「ペインごとに別マシン」を実現できる。

### 3.1 マルチ接続: `ConnectionManager`

新設サービス。`connectionId → 接続コンテキスト` のプールを持つ。

```dart
/// 1接続 = 1 bridge への 1 WebSocket。BridgeService と派生 Cubit を束ねる。
class BridgeConnection {
  final String id;            // connectionId（安定キー）
  final Machine machine;      // 接続先（MachineManager の Machine）
  final BridgeService bridge; // この接続専用インスタンス
  // 派生 Cubit はこの接続の bridge ストリームから生成
  // (ConnectionCubit / ActiveSessionsCubit / FileListCubit / GalleryCubit ...)
}

class ConnectionManager {
  final Map<String, BridgeConnection> _connections = {};
  Stream<List<BridgeConnection>> get connections;

  BridgeConnection connect(Machine machine);  // 既存なら再利用
  void disconnect(String connectionId);
  BridgeConnection? byId(String id);
}
```

- `main.dart` の単一 `BridgeService` を `ConnectionManager` に置換。
- グローバルに残すのは `ConnectionManager` と横断サービス（`MachineManagerService` / discovery）のみ。
- 接続系 Cubit は**ペイン（または接続）スコープの Provider** に降ろす。

### 3.2 セッション識別子の拡張

```
sessionId 単独  →  SessionRef { connectionId, sessionId }
```

- ペイン・タブ・履歴参照はすべて `SessionRef` を持つ。
- セッション画面は `connectionId` を受け取り、`ConnectionManager.byId(connectionId).bridge` を**ペインスコープの `Provider<BridgeService>` として供給**する薄いラッパ（`PaneScope`）で包む。
- これにより既存の `context.read<BridgeService>()` が「そのペインの接続」を返す。

### 3.3 分割レイアウト: 再帰分割ツリー

幅依存の `_WorkspaceLayoutMode` を、ユーザー操作の**再帰的な分割ツリー**に置換（デスクトップ時）。

```dart
sealed class PaneNode {}

/// 葉: 1 ペイン。中身は SessionRef か空（ピッカー）。
class LeafPane extends PaneNode {
  final String paneId;
  SessionRef? session;   // null = 空ペイン
}

/// 節: 縦/横分割。子とサイズ比を持つ。
class SplitPane extends PaneNode {
  final Axis axis;              // horizontal / vertical
  final List<PaneNode> children;
  final List<double> weights;   // 各子の比率（可動仕切りで更新）
}
```

- `PaneTreeCubit` がツリーと**フォーカス中ペイン**を管理。
- 操作: `splitFocused(Axis)` / `closeFocused()` / `focus(paneId)` / `setSession(paneId, SessionRef)` / `resize(...)`。
- 描画: ツリーを再帰的に `Row`/`Column` + `_WorkspaceResizeDivider` でレイアウト。葉は `PaneScope`(接続 inject) + 既存セッション画面。
- モバイル/狭画面: ツリーを無視して**フォーカス中の 1 葉だけ**を全画面表示（既存の single 相当）。

### 3.4 セッション選択 UI

- 空ペインに「接続を選ぶ → セッション/プロジェクトを選ぶ」ピッカー。
- 接続が 0 の場合はマシン接続フローへ（既存の接続 UI を流用）。
- 既存のセッション一覧を「接続でグルーピング」した集約ビューを用意（横断 `ActiveSessionsCubit` の代わりに `ConnectionManager` から合成）。

---

## 4. 段階プラン

| Phase | 内容 | 完了条件 |
|-------|------|---------|
| **1. 設計（本書）** | アーキ確定・合意 | レビュー済み |
| **2. マルチ接続バックエンド** | `ConnectionManager` + `BridgeConnection`、接続系 Cubit のスコープ化、`SessionRef` 化。UI は単一ペインのまま **複数接続を確立・切替できる**所まで | 2台同時接続して各セッションが混線せず動く |
| **3. 分割レイアウト** | `PaneTreeCubit` + 再帰描画、`PaneScope` で葉ごとに接続 inject、split/close/focus/resize | デスクトップで 2 ペイン以上に別マシンのセッションを表示できる |
| **4. 仕上げ** | tmux 風キーバインド、レイアウト永続化、ペイン間ドラッグ移動、空ペインピッカーの磨き込み | 実用レベル |

- 各 Phase 末に検証（`/mobile-automation` の E2E + `/self-review`）。
- Phase 2 と 3 は独立に検証可能なので分割コミット。

---

## 5. リスク / 留意点

- **グローバル singleton 前提の洗い出し**: `context.read<BridgeService>()` の利用箇所すべてが「どの接続か」を正しく解決する必要がある。ペインスコープ Provider で大半は透過になるが、横断画面（マシン一覧・設定・ギャラリー全体）は `ConnectionManager` 経由に書き換えが要る。
- **リソース**: N 接続 = N WebSocket + N 分のストリーム/Cubit。アイドル接続の扱い（保持 vs 切断）を決める。
- **再接続・状態管理**: 接続ごとに独立した reconnect。ペインが参照する接続が落ちた時の表示（再接続スピナー/オフライン）をペイン単位で。
- **永続化**: 分割レイアウト + 各ペインの `SessionRef` の保存・復元。接続先が消えている場合のフォールバック。
- **既存タブとの関係**: macOS タブ (`TabsCubit`) と分割ツリーの併用方針（タブ＝トップレベルのレイアウト集合、各タブが 1 つの分割ツリーを持つ、が素直）。
- **モバイル退行防止**: 狭画面は必ず single にフォールバック。分割ロジックがモバイルのパフォーマンスを劣化させないこと。

---

## 6. 未決事項（要判断）

1. アイドル接続は保持する？（メモリ vs 利便性）
2. タブと分割ツリーの関係: 「1 タブ = 1 分割ツリー」で良いか？
3. 同一セッションを複数ペインに同時表示する需要はある？（read 整合性の検討）
4. レイアウト永続化の粒度（アプリ全体 / マシンごと / プロジェクトごと）。
5. キーバインドは tmux 準拠（prefix キー方式）にするか、ネイティブなショートカットにするか。
