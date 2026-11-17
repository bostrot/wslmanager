import 'package:fluent_ui/fluent_ui.dart';
import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/pricing.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/nav/router.dart';

/// Announces a sale the website is running, on the home page of an install
/// that is not Pro. The caller decides that — a licensed install must not
/// mount this, because mounting it asks the website for the prices.
///
/// Shows nothing until the published document says a sale is on, and
/// nothing again once the user has closed it: a dismissed sale stays
/// dismissed, the next one (another id) is announced afresh.
class SaleBanner extends StatefulWidget {
  const SaleBanner({super.key});

  /// The id of the last sale the user closed the banner for.
  static const String dismissedPref = 'DismissedSale';

  @override
  State<SaleBanner> createState() => _SaleBannerState();
}

class _SaleBannerState extends State<SaleBanner> {
  PricingSale? _sale;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sale = await PricingService().runningSale();
    if (!mounted || sale == null) return;
    if (prefs.getString(SaleBanner.dismissedPref) == sale.id) return;
    setState(() => _sale = sale);
  }

  @override
  Widget build(BuildContext context) {
    final sale = _sale;
    if (sale == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: InfoBar(
        key: const ValueKey('test-sale-banner'),
        title: Text('sale-banner-text'.i18n([sale.name, sale.percentText])),
        severity: InfoBarSeverity.success,
        action: Button(
          key: const ValueKey('test-sale-banner-button'),
          onPressed: () {
            trackUpgradeClick('sale_banner');
            navigateGuarded('license', path: '/license');
          },
          child: Text('sale-banner-button'.i18n()),
        ),
        onClose: () {
          prefs.setString(SaleBanner.dismissedPref, sale.id);
          setState(() => _sale = null);
        },
      ),
    );
  }
}
