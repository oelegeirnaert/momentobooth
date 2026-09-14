import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:momento_booth/main.dart';
import 'package:momento_booth/managers/settings_web_server_manager.dart';
import 'package:momento_booth/views/components/indicators/subsystem_status_list.dart';
import 'package:momento_booth/views/onboarding_screen/components/wizard_page.dart';

class StatusPage extends StatelessWidget {
  const StatusPage({super.key});

  @override
  Widget build(BuildContext context) {
    return WizardPage(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(32.0),
                child: SvgPicture.asset(
                  'assets/svg/undraw_server-status_f685.svg',
                  clipBehavior: Clip.none,
                ),
              ),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 16.0),
                    child: Text(
                      "Initializing components",
                      style: FluentTheme.of(context).typography.title,
                    ),
                  ),
                  Expanded(child: SubsystemStatusList()),
                  const SizedBox(height: 12),
                  Text(
                    'Configure from browser',
                    style: FluentTheme.of(context).typography.subtitle,
                  ),
                  const SizedBox(height: 4),
                  FutureBuilder<List<String>>(
                    future: getIt<SettingsWebServerManager>().connectionUrls,
                    builder: (context, snapshot) {
                      final urls =
                          snapshot.data ??
                          [
                            'http://localhost:${SettingsWebServerManager.defaultPort}',
                            'http://127.0.0.1:${SettingsWebServerManager.defaultPort}',
                          ];

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final url in urls)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 1),
                              child: SelectableText(url),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
