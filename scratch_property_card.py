import re
import sys

def process():
    path = 'c:/Users/KNEST/necxa app/necxa.app/lib/screens/home_screen.dart'
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Find the start of class _PropertyCard
    match = re.search(r'class _PropertyCard extends StatelessWidget \{.*?Widget build\(BuildContext context\) \{.*?(?=Positioned\(\s*top: 10,\s*left: 10,\s*child: _TrustBadge)', content, re.DOTALL)
    
    if not match:
        print("Could not find the target block")
        return

    old_block = match.group(0)

    new_block = '''class _PropertyCard extends StatefulWidget {
  final PropertyContainer p;
  final AppState state;
  const _PropertyCard({required this.p, required this.state});

  @override
  State<_PropertyCard> createState() => _PropertyCardState();
}

class _PropertyCardState extends State<_PropertyCard> {
  int _currentIndex = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.p.core.images.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (mounted) {
          setState(() {
            _currentIndex = (_currentIndex + 1) % widget.p.core.images.length;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final state = widget.state;
    final saved = state.saved.contains(p.core.id);
    final isReserved = p.escrow.status == EscrowStatus.pending_escrow;

    return GestureDetector(
      onTap: () => state.openDetail(p.core.id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 250,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: C.cardDk,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isReserved ? C.red.withOpacity(.3) : C.border,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: p.core.images.isNotEmpty
                  ? AnimatedSwitcher(
                      duration: const Duration(milliseconds: 800),
                      child: CachedNetworkImage(
                        key: ValueKey<String>(p.core.images[_currentIndex]),
                        imageUrl: p.core.images[_currentIndex],
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        placeholder: (context, url) => Container(color: C.dim.withOpacity(0.1)),
                        errorWidget: (context, url, error) => Icon(Icons.error, color: C.dim),
                      ),
                    )
                  : Center(
                      child: Text(
                        p.core.propertyType == PropertyType.apartment ? '🏢' : '🏡',
                        style: const TextStyle(fontSize: 50),
                      ),
                    ),
            ),
            '''

    content = content.replace(old_block, new_block)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print("Successfully replaced _PropertyCard in home_screen.dart")

process()
