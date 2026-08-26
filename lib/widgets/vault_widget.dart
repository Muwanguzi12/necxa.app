import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../theme.dart';
import 'vault_buy_shards_overlay.dart';
import 'vault_deposit_overlay.dart';
import 'vault_sell_shards_overlay.dart';
import 'vault_withdraw_overlay.dart';

class VaultWidget extends StatefulWidget {
  const VaultWidget({super.key, required this.state});

  final AppState state;

  @override
  State<VaultWidget> createState() => _VaultWidgetState();
}

class _VaultWidgetState extends State<VaultWidget> {
  bool _fiatMasked = true;
  bool _coinsMasked = true;
  bool _escrowMasked = true;

  @override
  void initState() {
    super.initState();
    _refreshAfterFrame();
  }

  @override
  void didUpdateWidget(covariant VaultWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      _refreshAfterFrame();
    }
  }

  void _refreshAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.state.syncVault();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) => Column(
        children: [
          _WalletSyncHeader(
            isSyncing: widget.state.isWalletSyncing,
            error: widget.state.walletSyncError,
            lastSyncedAt: widget.state.walletLastSyncedAt,
            onRefresh: widget.state.syncVault,
          ),
          const SizedBox(height: 12),
          _VaultNodeCard(
            label: 'Your Balance',
            sub: 'Available to spend',
            value: _fiatMasked
                ? 'UGX ******'
                : !widget.state.hasVerifiedWallet
                ? 'UGX �'
                : 'UGX ${_formatNumber(widget.state.fiatBalance)}',
            color: const Color(0xFF3b82f6),
            masked: _fiatMasked,
            onToggleMask: () => setState(() => _fiatMasked = !_fiatMasked),
            actions: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _NodeAction(
                    icon: Icons.add,
                    label: 'Deposit',
                    onTap: () => _openDeposit(context),
                  ),
                ),
              ),
              Expanded(
                child: _NodeAction(
                  icon: Icons.arrow_upward,
                  label: 'Withdraw',
                  onTap: () => _openWithdraw(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _VaultNodeCard(
            label: 'Coins (NCX)',
            sub: 'Digital tokens',
            value: _coinsMasked
                ? '****** NCX'
                : !widget.state.hasVerifiedWallet
                ? '� NCX'
                : '${_formatNumber(widget.state.coinBalance)} NCX',
            color: const Color(0xFFeab308),
            masked: _coinsMasked,
            onToggleMask: () => setState(() => _coinsMasked = !_coinsMasked),
            actions: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _NodeAction(
                    icon: Icons.bolt,
                    label: 'Buy',
                    onTap: () => _openBuyCoins(context),
                  ),
                ),
              ),
              Expanded(
                child: _NodeAction(
                  icon: Icons.sync_alt,
                  label: 'Sell',
                  onTap: () => _openSellCoins(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _VaultNodeCard(
            label: 'Protected Funds',
            sub: 'Held in escrow',
            value: _escrowMasked
                ? 'UGX ******'
                : !widget.state.hasVerifiedWallet
                ? 'UGX �'
                : 'UGX ${_formatNumber(widget.state.escrowBalance)}',
            color: const Color(0xFF10b981),
            masked: _escrowMasked,
            onToggleMask: () {
              setState(() => _escrowMasked = !_escrowMasked);
            },
            isEscrow: true,
            actions: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _NodeAction(
                    icon: Icons.shield_outlined,
                    label: 'Protect',
                    onTap: () {},
                  ),
                ),
              ),
              Expanded(
                child: _NodeAction(
                  icon: Icons.history,
                  label: 'History',
                  onTap: () {},
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatNumber(double value) {
    final pattern = value == value.truncateToDouble() ? '#,##0' : '#,##0.00';
    return NumberFormat(pattern).format(value);
  }

  void _openDeposit(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VaultDepositOverlay(state: widget.state),
    );
  }

  void _openWithdraw(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VaultWithdrawOverlay(state: widget.state),
    );
  }

  void _openBuyCoins(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VaultBuyShardsOverlay(state: widget.state),
    );
  }

  void _openSellCoins(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VaultSellShardsOverlay(state: widget.state),
    );
  }
}

class _WalletSyncHeader extends StatelessWidget {
  const _WalletSyncHeader({
    required this.isSyncing,
    required this.error,
    required this.lastSyncedAt,
    required this.onRefresh,
  });

  final bool isSyncing;
  final String? error;
  final DateTime? lastSyncedAt;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            error ??
                (isSyncing
                    ? 'Refreshing wallet'
                    : lastSyncedAt == null
                    ? 'FINANCES'
                    : 'VERIFIED ${DateFormat('d MMM, HH:mm').format(lastSyncedAt!.toLocal())}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: dm(
              sz: 10,
              w: FontWeight.w700,
              ls: error == null && !isSyncing ? 1.5 : 0,
              c: error == null ? C.dim : Color(0xFFef4444),
            ),
          ),
        ),
        if (isSyncing)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          IconButton(
            onPressed: onRefresh,
            tooltip: 'Refresh wallet',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, size: 20),
          ),
      ],
    );
  }
}

class _VaultNodeCard extends StatelessWidget {
  const _VaultNodeCard({
    required this.label,
    required this.sub,
    required this.value,
    required this.color,
    required this.actions,
    required this.masked,
    required this.onToggleMask,
    this.isEscrow = false,
  });

  final String label;
  final String sub;
  final String value;
  final Color color;
  final List<Widget> actions;
  final bool masked;
  final VoidCallback onToggleMask;
  final bool isEscrow;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: C.text.withValues(alpha: .02),
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: color.withValues(alpha: .15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: syne(sz: 10, w: FontWeight.w900, ls: 2, c: color),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      sub,
                      style: dm(sz: 9, c: C.dim, fs: FontStyle.italic),
                    ),
                  ],
                ),
              ),
              if (isEscrow) const _EscrowSyncDot(),
              IconButton(
                onPressed: onToggleMask,
                tooltip: masked ? 'Show $label' : 'Hide $label',
                icon: Icon(
                  masked
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: C.sub,
                  size: 20,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 36,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: FittedBox(
                key: ValueKey(value),
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  style: syne(
                    sz: 28,
                    w: FontWeight.w900,
                    fs: FontStyle.italic,
                    c: color,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(children: actions),
        ],
      ),
    );
  }
}

class _EscrowSyncDot extends StatelessWidget {
  const _EscrowSyncDot();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Color(0xFF10b981),
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 8),
      Text('Protected', style: dm(sz: 9, c: C.dim)),
    ],
  );
}

class _NodeAction extends StatelessWidget {
  const _NodeAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: C.text.withValues(alpha: .05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: C.text.withValues(alpha: .05)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: C.text, size: 14),
            const SizedBox(width: 8),
            Text(label, style: dm(sz: 10, w: FontWeight.w700, ls: 1)),
          ],
        ),
      ),
    );
  }
}


