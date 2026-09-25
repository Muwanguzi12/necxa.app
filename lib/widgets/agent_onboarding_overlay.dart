import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';

class AgentOnboardingOverlay extends StatefulWidget {
  final AppState state;
  const AgentOnboardingOverlay({super.key, required this.state});

  static void show(BuildContext context, AppState state) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AgentOnboardingOverlay(state: state),
    );
  }

  @override
  State<AgentOnboardingOverlay> createState() => _AgentOnboardingOverlayState();
}

class _AgentOnboardingOverlayState extends State<AgentOnboardingOverlay> {
  int _step = 0;
  bool _submitting = false;

  final Map<String, bool> _docs = {
    'Business License': false,
    'Tax ID / TIN': false,
    'Agency Permit': false,
    'Lead Agent ID': false,
  };

  void _uploadDoc(String docName) async {
    // Simulate upload delay
    await Future.delayed(const Duration(milliseconds: 1500));
    setState(() => _docs[docName] = true);
  }

  void _submitApplication() async {
    setState(() => _submitting = true);
    try {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('? Agent verification submitted!')),
      );
      if (!mounted) return;
      setState(() => _submitting = false);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Verification failed to start: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.9,
      decoration: BoxDecoration(
        color: C.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border(top: BorderSide(color: C.dim)),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 48, height: 4,
                    decoration: BoxDecoration(color: C.dim, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 24),
                
                if (_step == 0) _buildIntro()
                else if (_step == 1) _buildDocuments(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIntro() {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('??', style: TextStyle(fontSize: 32)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Become a Verified Agent', style: syne(sz: 20, w: FontWeight.w700)),
                    Text('Necxa East Africa Protocol', style: dm(sz: 12, c: C.brand)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Agents on Necxa are fully verified nodes, ensuring that every transaction '
            'is backed by a legally accountable professional.',
            style: dm(sz: 13, c: C.dim, h: 1.5),
          ),
          const SizedBox(height: 32),
          Text('Commission Structure', style: syne(sz: 16, w: FontWeight.w700)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: C.blue.withOpacity(.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: C.blue.withOpacity(.2)),
            ),
            child: Column(
              children: [
                const _CommissionRow(label: 'Agent Commission', value: '5%', desc: 'Your earnings on final sale', color: C.green),
                Divider(color: C.dim, height: 24),
                _CommissionRow(label: 'Necxa Protocol Fee', value: '2%', desc: 'Platform service fee', color: C.brand),
                const SizedBox(height: 12),
                Text(
                  'The 10% Escrow Unlock fee paid by buyers to view your property details is kept entirely by you as a pre-commission for serious leads.',
                  style: dm(sz: 11, c: C.dim, h: 1.5),
                ),
              ],
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => setState(() => _step = 1),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(gradient: brandGrad, borderRadius: BorderRadius.circular(16)),
              child: Center(child: Text('Agree & Continue ?', style: syne(sz: 15, c: C.bg))),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildDocuments() {
    final allDone = _docs.values.every((v) => v);
    
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Mandatory Documents', style: syne(sz: 20, w: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            'Upload your legal documents for AI verification. '
            'Your data is sharded in the Neural Core.',
            style: dm(sz: 13, c: C.dim, h: 1.5),
          ),
          const SizedBox(height: 24),
          
          Expanded(
            child: ListView(
              children: [
                _DocTile(
                  icon: '??',
                  title: 'Business License',
                  sub: 'Certificate of Incorporation',
                  done: _docs['Business License']!,
                  onTap: () => _uploadDoc('Business License'),
                ),
                _DocTile(
                  icon: '??',
                  title: 'Tax ID / TIN',
                  sub: 'Govt-issued Tax Identification',
                  done: _docs['Tax ID / TIN']!,
                  onTap: () => _uploadDoc('Tax ID / TIN'),
                ),
                _DocTile(
                  icon: '??',
                  title: 'Agency Permit',
                  sub: 'Real Estate Regulatory License',
                  done: _docs['Agency Permit']!,
                  onTap: () => _uploadDoc('Agency Permit'),
                ),
                _DocTile(
                  icon: '??',
                  title: 'Lead Agent ID',
                  sub: 'National ID or Passport (Live AI)',
                  done: _docs['Lead Agent ID']!,
                  onTap: () async {
                    await widget.state.doIdScan('Uganda', 'National ID');
                    if (widget.state.idDone) {
                      setState(() => _docs['Lead Agent ID'] = true);
                    }
                  },
                ),
              ],
            ),
          ),
          
          GestureDetector(
            onTap: allDone && !_submitting ? _submitApplication : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                gradient: allDone ? brandGrad : null,
                color: allDone ? null : C.brand.withOpacity(.2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: _submitting
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: C.bg, strokeWidth: 2)),
                          const SizedBox(width: 10),
                          Text('AI Verifying Agent...', style: syne(sz: 15, c: C.bg)),
                        ],
                      )
                    : Text(allDone ? 'Submit Application' : 'Upload All Documents', style: syne(sz: 15, c: C.bg)),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _CommissionRow extends StatelessWidget {
  final String label, value, desc;
  final Color color;
  const _CommissionRow({required this.label, required this.value, required this.desc, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: color.withOpacity(.15), shape: BoxShape.circle),
          child: Text(value, style: syne(sz: 14, w: FontWeight.w700, c: color)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: dm(sz: 14, w: FontWeight.w600)),
              Text(desc, style: dm(sz: 11, c: C.dim)),
            ],
          ),
        ),
      ],
    );
  }
}

class _DocTile extends StatelessWidget {
  final String icon, title, sub;
  final bool done;
  final VoidCallback onTap;
  const _DocTile({required this.icon, required this.title, required this.sub, required this.done, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: done ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: done ? C.green.withOpacity(.08) : C.text.withOpacity(.03),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: done ? C.green.withOpacity(.4) : C.dim),
        ),
        child: Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: syne(sz: 15, w: FontWeight.w700, c: done ? C.green : C.text)),
                  Text(sub, style: dm(sz: 11, c: C.dim)),
                ],
              ),
            ),
            if (done)
              const Icon(Icons.check_circle, color: C.green)
            else
              Icon(Icons.upload_file, color: C.dim),
          ],
        ),
      ),
    );
  }
}


