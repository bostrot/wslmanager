import 'package:flutter/scheduler.dart';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wsl2distromanager/api/deep_link.dart';
import 'package:wsl2distromanager/api/license_manager.dart';
import 'package:wsl2distromanager/api/pricing.dart';
import 'package:wsl2distromanager/api/purchase_routes.dart';
import 'package:wsl2distromanager/api/vm/vm_platform.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:provider/provider.dart';

class LicenseScreen extends StatefulWidget {
  const LicenseScreen({Key? key, this.appleHost, this.storeSellsPro})
      : super(key: key);

  /// Test seam. Which host's purchase routes to render; defaults to this
  /// machine's. Only tests pass it — the Windows layout has two buy cards
  /// where the Mac has one, and neither dev host can pump the other's.
  @visibleForTesting
  final bool? appleHost;

  /// Test seam. Whether the Store listing still sells Pro; defaults to what
  /// [LicenseManager.storeSellsPro] says, which is "yes" only until the
  /// scheduled flip has happened.
  @visibleForTesting
  final bool? storeSellsPro;

  @override
  State<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends State<LicenseScreen> {
  bool get _isApple => widget.appleHost ?? isAppleHost;

  /// The ways this host can buy Pro today.
  List<PurchaseRoute> get _routes =>
      purchaseRoutesFor(apple: _isApple, storeSellsPro: _storeSellsPro);

  /// Whether the Microsoft Store listing still sells Pro. Read once per
  /// build rather than per widget so every part of the screen tells the
  /// same story on the day the listing flips.
  bool get _storeSellsPro =>
      widget.storeSellsPro ?? LicenseManager.storeSellsPro;

  bool _isLoading = false;
  bool _isActivating = false;

  /// What the website cards quote. Starts on the compiled-in US dollar
  /// amounts so the first frame has a price, and moves to the live prices
  /// in this machine's currency once the catalogue and the OS region have
  /// been read. A Store card never uses it: the Store page has its own.
  PricingQuote _quote = PricingQuote.bundled();
  final TextEditingController _keyController = TextEditingController();
  final DeepLinkService _deepLinks = DeepLinkService();

  @override
  void initState() {
    super.initState();
    // Reported like every other screen's. This one was the exception, which
    // left the number of people who reach the paywall — the denominator for
    // every conversion question about it — unknowable.
    plausible.event(page: 'license');

    // Defer init to avoid setState during build (LicenseManager ChangeNotifier
    // triggers Provider rebuilds that cascade into this widget's build phase)
    SchedulerBinding.instance.addPostFrameCallback((_) => _loadStatus());

    // Listened for on every host: a key bought on the website unlocks Pro
    // anywhere, and only macOS registers the scheme today, so on Windows and
    // Linux the channel simply has nothing on the other end and both calls
    // are inert rather than wrong.
    _deepLinks.listen(_handleLink);
    SchedulerBinding.instance.addPostFrameCallback((_) async {
      final pending = await _deepLinks.takePendingLink();
      if (pending != null) _handleLink(pending);
    });
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  /// A `wslmanager://license?key=...` link from the browser after checkout.
  /// Fills the field as well as activating, so a failure leaves the user
  /// with something to retry rather than an empty box.
  void _handleLink(Uri link) {
    final key = DeepLinkService.licenseKeyOf(link);
    if (key == null || !mounted) return;
    _keyController.text = key;
    _activate();
  }

  Future<void> _activate() async {
    final key = _keyController.text.trim();
    if (key.isEmpty || _isActivating) return;

    setState(() => _isActivating = true);
    final result = await LicenseManager().activate(key);
    if (!mounted) return;
    setState(() => _isActivating = false);

    switch (result) {
      case LicenseActivation.success:
        _keyController.clear();
        Notify.message('activate-success-text'.i18n(),
            severity: InfoBarSeverity.success);
        break;
      case LicenseActivation.invalid:
        Notify.message('activate-invalid-text'.i18n(),
            severity: InfoBarSeverity.error);
        break;
      case LicenseActivation.network:
        Notify.message('activate-network-text'.i18n(),
            severity: InfoBarSeverity.warning);
        break;
    }
  }

  /// Re-reads the entitlement. With [askStore], also asks the Store when
  /// this user acquired the app — the only evidence a reinstalled Store copy
  /// has — and waits for the answer, so "Check again" reports what the
  /// Store said rather than what it said a day ago.
  Future<void> _loadStatus({bool askStore = false}) async {
    setState(() {
      _isLoading = true;
    });
    await LicenseManager().init();
    if (askStore) {
      await LicenseManager().restoreFromStore(force: true);
    }
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
    // Only once the entitlement is known: a Pro user is shown no buy card,
    // so there is no price to quote and nothing to fetch for them.
    if (!LicenseManager().isPro) await _loadQuote();
  }

  /// Whether the quote has been asked for; once is enough per visit, and
  /// "Check again" re-reads the entitlement without re-asking for prices.
  bool _quoteRequested = false;

  /// The live prices, in this machine's currency. Never throws and never
  /// leaves the card empty: the service answers with the last document it
  /// fetched, or the compiled-in dollars, when the website is unreachable.
  Future<void> _loadQuote() async {
    if (_quoteRequested) return;
    _quoteRequested = true;
    final quote = await PricingService().quote();
    if (!mounted) return;
    setState(() => _quote = quote);
  }

  /// What a website route is sold at right now: the live quote, or the
  /// compiled-in dollars until one arrives. Null for the Store, whose own
  /// page shows the price.
  LocalizedPrice? _quotedPrice(PurchaseRoute route) {
    final lookupKey = route.lookupKey;
    if (lookupKey == null) return null;
    return _quote[lookupKey] ?? PricingQuote.bundled()[lookupKey];
  }

  /// The price line for one card: the live quote for a website route, the
  /// fixed copy for the Store.
  String _priceLine(PurchaseRoute route) {
    if (route.lookupKey == null) return route.priceKey.i18n();
    return route.priceKey.i18n([_quotedPrice(route)?.text ?? '']);
  }

  Future<void> _openBuyPage(PurchaseRoute route) async {
    // Before the launch, not after: the Store and the website are counted
    // the same way whether or not the handover works, and a throw below
    // must not lose the click.
    final price = _quotedPrice(route);
    plausible.event(name: 'license_buy_clicked', props: {
      'route': route.id.name,
      'host': _isApple ? 'macos' : 'windows',
      // What the buyer was quoted, so a click can be set against the
      // price and the currency it was made at — and a price change can be
      // read off the clicks rather than guessed from the calendar.
      if (price != null) 'currency': price.currency,
      if (price != null) 'amount': '${price.amount}',
    });

    // No canLaunchUrl gate: on Windows it reports false for perfectly
    // launchable https URLs, which silently disabled the one thing this
    // screen asks the user to do (audit PS-07).
    try {
      await launchUrl(Uri.parse(route.url),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // .value(), not create(): Provider must not dispose() this app-wide
    // singleton when the screen unmounts.
    return ChangeNotifierProvider.value(
      value: LicenseManager(),
      child: Consumer<LicenseManager>(
        builder: (context, manager, _) {
          if (_isLoading) {
            return const Center(child: ProgressRing());
          }

          return Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24.0),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildHeader(manager),
                          const SizedBox(height: 24),

                          if (manager.isPro) ...[
                            _buildStatusCard(manager),
                            const SizedBox(height: 20),
                            // The feature list used to live only in the
                            // non-Pro branch, so a paying user could never
                            // see what their plan includes (audit PS-04).
                            Card(
                              padding: const EdgeInsets.all(20),
                              borderRadius: BorderRadius.circular(10),
                              child: _buildComparisonTable(),
                            ),
                          ] else ...[
                            // Not Pro: lead with the pitch, status after.
                            // Windows offers two routes while the Store sells
                            // Pro — the Store, and the website for buyers who
                            // would rather skip it — so this is a list, not a
                            // single card.
                            for (final entry in _routes.asMap().entries) ...[
                              _buildBuySection(entry.value,
                                  leading: entry.key == 0),
                              const SizedBox(height: 20),
                            ],
                            // Key entry belongs on every host now: a licence
                            // bought on the website has to be redeemable
                            // wherever it was bought.
                            _buildActivationSection(),
                            const SizedBox(height: 20),
                            // Shown once, under whichever buy cards this host
                            // offers, rather than repeated inside each.
                            Card(
                              padding: const EdgeInsets.all(20),
                              borderRadius: BorderRadius.circular(10),
                              child: _buildComparisonTable(),
                            ),
                            const SizedBox(height: 20),
                            _buildStatusCard(manager),
                            const SizedBox(height: 12),
                            _buildRestoreRow(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// "Already bought Pro but the app shows Free?" — the entitlement probe is
  /// a single package-identity check with, before this, no way to re-run it
  /// visibly and no support path when it is wrong (audit PS-05).
  Widget _buildRestoreRow() {
    return Row(
      children: [
        // Flexible, not bare: the hint is a full sentence and in several
        // locales it is long enough to push the two controls off the row.
        Flexible(
          child: Text('restore-hint-text'.i18n(),
              style: TextStyle(
                  fontSize: 12, color: secondaryTextColor(context))),
        ),
        const SizedBox(width: 8),
        Button(
          key: const ValueKey('test-license-recheck'),
          onPressed: () async {
            await _loadStatus(askStore: true);
            if (!mounted) return;
            Notify.message(
                LicenseManager().isPro
                    ? 'restore-found-text'.i18n()
                    : restoreNotFoundKeyFor(storeSellsPro: _storeSellsPro)
                        .i18n(),
                severity: LicenseManager().isPro
                    ? InfoBarSeverity.success
                    : InfoBarSeverity.warning);
          },
          child: Text('restore-check-text'.i18n()),
        ),
        const SizedBox(width: 8),
        HyperlinkButton(
          onPressed: () async {
            try {
              await launchUrl(Uri.parse(githubIssues),
                  mode: LaunchMode.externalApplication);
            } catch (_) {}
          },
          child: Text('restore-support-text'.i18n()),
        ),
      ],
    );
  }

  Widget _buildHeader(LicenseManager manager) {
    final accent = FluentTheme.of(context).accentColor;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                accent.withValues(alpha: 0.25),
                accent.withValues(alpha: 0.08),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(FluentIcons.crown, size: 22, color: accent),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The nav item and the page it opens now share a name — the nav
            // said "Upgrade to Pro" and the page said "License" (audit PS-06).
            Text(
              manager.isPro
                  ? 'license-text'.i18n()
                  : 'upgrade-pro-text'.i18n(),
              style: FluentTheme.of(context).typography.titleLarge,
            ),
            const SizedBox(height: 2),
            Text(
              'store-buy-info-text'.i18n(),
              style: FluentTheme.of(context).typography.bodyStrong?.copyWith(
                    color: secondaryTextColor(context),
                    fontWeight: FontWeight.normal,
                  ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusCard(LicenseManager manager) {
    final isPro = manager.isPro;
    final color = isPro
        ? FluentTheme.of(context).accentColor
        : secondaryTextColor(context);
    final isDark = FluentTheme.of(context).brightness.isDark;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            color.withValues(alpha: isDark ? 0.16 : 0.12),
            color.withValues(alpha: isDark ? 0.04 : 0.03),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isPro ? FluentIcons.crown : FluentIcons.info,
              color: color,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isPro ? 'plan-pro'.i18n() : 'plan-free'.i18n(),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  isPro
                      ? (manager.isKeyLicensed
                          ? 'plan-key-detail'.i18n()
                          : 'plan-store-detail'.i18n())
                      : (isAppleHost
                              ? 'plan-free-detail-vm'
                              : 'plan-free-detail')
                          .i18n(),
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
                if (manager.isKeyLicensed && manager.licenseKey != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    manager.licenseKey!,
                    key: const ValueKey('test-license-key-display'),
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: secondaryTextColor(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One purchase route as a card. The Store card leads on Windows while the
  /// Store still sells Pro and the website card follows it; everywhere else
  /// the website card is the only one, and leads.
  ///
  /// [leading] is whether this is the first card on the screen. The first
  /// card keeps the original test keys whichever route it happens to be, so
  /// what the rest of the suite looks for is always the CTA the screen leads
  /// with.
  Widget _buildBuySection(PurchaseRoute route, {required bool leading}) {
    final isStore = route.id == PurchaseRouteId.store;
    return Card(
      padding: const EdgeInsets.all(20),
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            route.titleKey.i18n(),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            route.detailKey.i18n(),
            style: TextStyle(fontSize: 13, color: secondaryTextColor(context)),
          ),
          const SizedBox(height: 8),
          // The one question every buyer has first was the one thing the
          // screen never answered (audit PS-02). A website card quotes the
          // live price in this machine's currency; a Store page shows the
          // buyer's own currency itself.
          Text(
            _priceLine(route),
            key: ValueKey(
                leading ? 'test-license-price' : 'test-license-web-price'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: ValueKey(leading
                  ? 'test-license-store-button'
                  : 'test-license-web-buy-button'),
              onPressed: () => _openBuyPage(route),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(isStore ? FluentIcons.shop : FluentIcons.globe,
                        size: 16),
                    const SizedBox(width: 8),
                    Text(route.buttonKey.i18n()),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Key entry, on every host. Two ways in: the browser hands the key over
  /// through `wslmanager://` right after checkout — macOS only for now, since
  /// it is the only runner that registers the scheme — or the user pastes it
  /// here, which is also the path for a second machine, where no purchase
  /// just happened.
  Widget _buildActivationSection() {
    return Card(
      padding: const EdgeInsets.all(20),
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'activate-title'.i18n(),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            activateDetailKeyFor(
                    apple: _isApple, storeSellsPro: _storeSellsPro)
                .i18n(),
            style: TextStyle(fontSize: 13, color: secondaryTextColor(context)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextBox(
                  key: const ValueKey('test-license-key-field'),
                  controller: _keyController,
                  placeholder: 'WSLM-XXXXX-XXXXX-XXXXX-XXXXX',
                  onSubmitted: (_) => _activate(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('test-license-activate'),
                onPressed: _isActivating ? null : _activate,
                child: _isActivating
                    ? const SizedBox(
                        width: 16, height: 16, child: ProgressRing(strokeWidth: 2))
                    : Text('activate-btn'.i18n()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildComparisonTable() {
    final accent = FluentTheme.of(context).accentColor;
    // Each row: [i18n key, included in Free, included in Pro].
    final rows = <List<Object>>[
      // On macOS the free tier manages native VMs, and the AI Workspace
      // (a WSL-only feature) must not be sold there.
      [
        isAppleHost
            ? 'core-vm-management-feature'
            : 'core-wsl-management-feature',
        true,
        true
      ],
      ['ai-config-assistant-feature', false, true],
      // "Smart Recommendations" and "Script Generation" are gone: the first
      // ships in the free tier and the second does not exist anywhere in the
      // app, so both rows were selling something other than what Pro is
      // (audit PS-01).
      ['error-diagnosis-feature', false, true],
      // Listed on every host: AppleVmApi sets `aiWorkspace: true`, so the Mac
      // build does ship it. Hiding the row here sold macOS buyers a Pro tier
      // with a feature missing that they were in fact paying for.
      ['ai-workspace-feature', false, true],
      ['mcp-server-feature', false, true],
      ['web-dashboard-feature', false, true],
    ];

    const columnWidth = 64.0;
    Widget cell(bool included) => SizedBox(
          width: columnWidth,
          child: Semantics(
            label: included
                ? 'included-text'.i18n()
                : 'notincluded-text'.i18n(),
            child: Icon(
              included ? FluentIcons.check_mark : FluentIcons.cancel,
              size: 14,
              color: included ? accent : secondaryTextColor(context),
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'compare-plans-text'.i18n(),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: surfaceBorderColor(context)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: subtleFillColor(context),
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(8)),
                ),
                child: Row(
                  children: [
                    const Expanded(child: SizedBox.shrink()),
                    SizedBox(
                      width: columnWidth,
                      child: Text('plan-free-short'.i18n(),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: secondaryTextColor(context))),
                    ),
                    SizedBox(
                      width: columnWidth,
                      child: Text('plan-pro-short'.i18n(),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: accent)),
                    ),
                  ],
                ),
              ),
              for (final row in rows)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text((row[0] as String).i18n(),
                            style: const TextStyle(fontSize: 12)),
                      ),
                      cell(row[1] as bool),
                      cell(row[2] as bool),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('* ',
                style: TextStyle(
                    fontSize: 11, color: secondaryTextColor(context))),
            Expanded(
              child: Text(
                'byok-required-note'.i18n(),
                style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: secondaryTextColor(context)),
              ),
            ),
          ],
        ),
      ],
    );
  }

}
