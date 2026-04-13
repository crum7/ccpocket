import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart' as intl;

import '../../../l10n/app_localizations.dart';
import '../../../services/revenuecat_service.dart';
import '../../../widgets/supporter_badge.dart';
import '../../../router/app_router.dart';

enum _SupportEntryVariant { inactive, oneTime, active }

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

        final variant = _variantForState(state);
        final isActive = variant == _SupportEntryVariant.active;
        final title = _titleForVariant(l, variant);
        final subtitle = _subtitleForVariant(context, l, state, variant);
        final icon = _iconForVariant(variant);
        final cardColor = _colorForVariant(cs, variant);
        final iconBackgroundColor = _iconBackgroundForVariant(cs, variant);
        final borderSide = _borderForVariant(cs, variant);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            margin: EdgeInsets.zero,
            color: cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: borderSide,
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
                      decoration: BoxDecoration(
                        color: iconBackgroundColor,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: cs.primary, size: 24),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                title,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              if (isActive) ...[
                                const SizedBox(width: 8),
                                const SupporterBadge(),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  _SupportEntryVariant _variantForState(SupportCatalogState state) {
    if (state.isSupporter) return _SupportEntryVariant.active;
    if (state.summary.hasActivity) return _SupportEntryVariant.oneTime;
    return _SupportEntryVariant.inactive;
  }

  String _titleForVariant(AppLocalizations l, _SupportEntryVariant variant) {
    return switch (variant) {
      _SupportEntryVariant.inactive => l.supportEntryInactiveTitle,
      _SupportEntryVariant.oneTime => l.supportEntryOneTimeTitle,
      _SupportEntryVariant.active => l.supportEntryActiveTitle,
    };
  }

  String _subtitleForVariant(
    BuildContext context,
    AppLocalizations l,
    SupportCatalogState state,
    _SupportEntryVariant variant,
  ) {
    return switch (variant) {
      _SupportEntryVariant.inactive => l.supportEntryInactiveSubtitle,
      _SupportEntryVariant.oneTime => l.supportEntryOneTimeSubtitle,
      _SupportEntryVariant.active when state.summary.supporterSince != null =>
        l.supportEntryActiveSubtitle(
          _formatSupportMonthYear(context, state.summary.supporterSince!),
        ),
      _SupportEntryVariant.active => l.supporterStatusActive,
    };
  }

  IconData _iconForVariant(_SupportEntryVariant variant) {
    return switch (variant) {
      _SupportEntryVariant.inactive => Icons.favorite_border,
      _SupportEntryVariant.oneTime => Icons.favorite_outline,
      _SupportEntryVariant.active => Icons.favorite,
    };
  }

  Color _colorForVariant(ColorScheme cs, _SupportEntryVariant variant) {
    return switch (variant) {
      _SupportEntryVariant.inactive => cs.surfaceContainerHigh,
      _SupportEntryVariant.oneTime => Color.alphaBlend(
        cs.secondary.withValues(alpha: 0.04),
        cs.surfaceContainerHigh,
      ),
      _SupportEntryVariant.active => Color.alphaBlend(
        cs.primary.withValues(alpha: 0.08),
        cs.surfaceContainerHigh,
      ),
    };
  }

  Color _iconBackgroundForVariant(
    ColorScheme cs,
    _SupportEntryVariant variant,
  ) {
    return switch (variant) {
      _SupportEntryVariant.inactive => cs.surfaceContainerHighest,
      _SupportEntryVariant.oneTime => cs.secondaryContainer.withValues(
        alpha: 0.5,
      ),
      _SupportEntryVariant.active => cs.primaryContainer.withValues(alpha: 0.8),
    };
  }

  BorderSide _borderForVariant(ColorScheme cs, _SupportEntryVariant variant) {
    return switch (variant) {
      _SupportEntryVariant.inactive => BorderSide(
        color: cs.outlineVariant,
        width: 1,
      ),
      _SupportEntryVariant.oneTime => BorderSide(
        color: cs.secondary.withValues(alpha: 0.2),
        width: 1,
      ),
      _SupportEntryVariant.active => BorderSide(
        color: cs.primary.withValues(alpha: 0.35),
        width: 1.5,
      ),
    };
  }

  String _formatSupportMonthYear(BuildContext context, DateTime date) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    return intl.DateFormat.yMMMM(locale).format(date);
  }
}
