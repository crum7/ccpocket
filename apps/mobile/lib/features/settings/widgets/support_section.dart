import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/revenuecat_service.dart';
import '../../../widgets/supporter_badge.dart';
import '../../../router/app_router.dart';

class SupportSectionCard extends StatelessWidget {
  const SupportSectionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final revenueCat = context.read<RevenueCatService>();
    final l = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return ValueListenableBuilder<SupportCatalogState>(
      valueListenable: revenueCat.catalogState,
      builder: (context, state, _) {
        if (!state.isAvailable && state.errorMessage == null) {
          return const SizedBox.shrink();
        }

        final isActive = state.isSupporter;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            margin: EdgeInsets.zero,
            color: isActive ? cs.primaryContainer : cs.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: isActive
                  ? BorderSide(
                      color: cs.primary.withValues(alpha: 0.3),
                      width: 1.5,
                    )
                  : BorderSide(color: cs.outlineVariant, width: 1),
            ),
            child: InkWell(
              key: const ValueKey('supporter_entry_button'),
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                context.pushRoute(const SupporterRoute());
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: isActive
                          ? BoxDecoration(
                              color: cs.primary.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            )
                          : null,
                      child: Icon(
                        isActive ? Icons.favorite : Icons.favorite_border,
                        color: cs.primary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                l.supporterTitle,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: isActive
                                          ? cs.onPrimaryContainer
                                          : null,
                                    ),
                              ),
                              if (isActive) ...[
                                const SizedBox(width: 8),
                                const SupporterBadge(),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isActive
                                ? l.supporterStatusActive
                                : l.supporterStatusInactive,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: isActive
                                      ? cs.onPrimaryContainer.withValues(
                                          alpha: 0.8,
                                        )
                                      : cs.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      color: isActive
                          ? cs.onPrimaryContainer.withValues(alpha: 0.5)
                          : cs.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
