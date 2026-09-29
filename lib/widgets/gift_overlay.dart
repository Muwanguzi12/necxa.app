import 'package:flutter/material.dart';
import '../app_state.dart';
import '../screens/community/gift_container.dart';

class GiftOverlay extends StatelessWidget {
  final AppState state;
  final String? receiverId;
  final String? postId;
  final String? contextType;
  final void Function(String emoji, String name, int price, int fee)? onSend;

  const GiftOverlay({
    super.key,
    required this.state,
    this.receiverId,
    this.postId,
    this.contextType,
    this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return GiftContainer(
      state: state,
      receiverId: receiverId ?? state.targetProfileId ?? '',
      postId: postId ?? state.listingId,
      contextType: contextType,
      onDismiss: () => Navigator.pop(context),
    );
  }
}
