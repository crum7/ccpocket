import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ccpocket/features/tabs/tabs_cubit.dart';
import 'package:ccpocket/features/tabs/tabs_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('TabEntry round-trips through json', () {
    const entry = TabEntry(
      id: 'tab_1',
      sessionId: 's1',
      provider: TabProvider.codex,
      projectPath: '/p',
      gitBranch: 'main',
      initialPermissionMode: 'auto',
      initialSandboxMode: 'workspace-write',
    );
    final restored = TabEntry.fromJson(entry.toJson());
    expect(restored.sessionId, 's1');
    expect(restored.provider, TabProvider.codex);
    expect(restored.projectPath, '/p');
    expect(restored.gitBranch, 'main');
    expect(restored.initialPermissionMode, 'auto');
    expect(restored.initialSandboxMode, 'workspace-write');
  });

  test('persists open tabs + active index and reads them back', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cubit = TabsCubit(prefs: prefs);

    cubit.openSession(
      sessionId: 's1',
      provider: TabProvider.claude,
      projectPath: '/a',
    );
    cubit.openSession(
      sessionId: 's2',
      provider: TabProvider.codex,
      projectPath: '/b',
    );
    await Future<void>.delayed(Duration.zero); // let the listener persist

    final restored = cubit.readPersisted();
    expect(restored.tabs.map((t) => t.sessionId), ['s1', 's2']);
    expect(restored.activeIndex, 2);

    await cubit.close();
  });

  test('does not persist pending tabs', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final cubit = TabsCubit(prefs: prefs);

    cubit.openSession(
      sessionId: 'pending',
      provider: TabProvider.claude,
      isPending: true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(cubit.readPersisted().tabs, isEmpty);
    await cubit.close();
  });
}
