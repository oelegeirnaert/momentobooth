import 'package:fluent_ui/fluent_ui.dart';
import 'package:momento_booth/app_localizations.dart';
import 'package:momento_booth/models/photo_capture.dart';
import 'package:momento_booth/views/components/dialogs/modal_dialog.dart';

class ImmichPhotoSelectionDialog extends StatefulWidget {
  final List<PhotoCapture> photos;
  final Future<void> Function(List<PhotoCapture> photos) onConfirm;

  const ImmichPhotoSelectionDialog({
    super.key,
    required this.photos,
    required this.onConfirm,
  });

  @override
  State<ImmichPhotoSelectionDialog> createState() =>
      _ImmichPhotoSelectionDialogState();
}

class _ImmichPhotoSelectionDialogState
    extends State<ImmichPhotoSelectionDialog> {
  late final Set<int> selected = Set<int>.from(
    List<int>.generate(widget.photos.length, (index) => index),
  );
  bool uploading = false;
  Object? error;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    return ModalDialog(
      title: localizations.wallPhotoSelectionTitle,
      body: SizedBox(
        width: 700,
        height: 420,
        child: uploading ? _uploadingBody() : _selectionBody(),
      ),
      actions: uploading
          ? const []
          : [
              Button(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(localizations.genericCancelButton),
              ),
              FilledButton(
                onPressed: selected.isEmpty ? null : _confirm,
                child: Text(
                  localizations.wallPhotoSelectionShowButton(selected.length),
                ),
              ),
            ],
    );
  }

  Widget _selectionBody() {
    final localizations = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(localizations.wallPhotoSelectionDescription),
        const SizedBox(height: 16),
        Expanded(
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              mainAxisExtent: 170,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: widget.photos.length,
            itemBuilder: (context, index) {
              final photo = widget.photos[index];
              final isSelected = selected.contains(index);
              return GestureDetector(
                onTap: () => setState(() {
                  if (isSelected) {
                    selected.remove(index);
                  } else {
                    selected.add(index);
                  }
                }),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(photo.data, fit: BoxFit.cover),
                    if (isSelected)
                      const Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(
                            FluentIcons.check_mark,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        width: double.infinity,
                        color: Colors.black.withValues(alpha: 0.65),
                        padding: const EdgeInsets.all(4),
                        child: Text(
                          photo.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(localizations.wallPhotoSelectionError(error.toString())),
        ],
      ],
    );
  }

  Widget _uploadingBody() {
    final localizations = AppLocalizations.of(context)!;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ProgressRing(),
        SizedBox(height: 16),
        Text(localizations.wallPhotoSelectionPreparing),
      ],
    );
  }

  Future<void> _confirm() async {
    setState(() {
      uploading = true;
      error = null;
    });

    try {
      await widget.onConfirm(
        selected.map((index) => widget.photos[index]).toList(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        uploading = false;
        error = exception;
      });
    }
  }
}
