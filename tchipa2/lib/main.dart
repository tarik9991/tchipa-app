import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ============================================
// CONFIGURATION
// ============================================
// Orders are sent to the agent: on WhatsApp when kAgentWhatsapp is set
// (international format, digits only, e.g. '213555123456'), else Telegram
// with the order text copied to the clipboard.
const String kAgentTelegram = 'https://t.me/c/3983752002/1';
const String kAgentWhatsapp = '';
// Photos are stored on the VPS (tools/vps_photos.cjs, backend/deploy/t2-photos.conf).
// Fallbacks: the nginx Yupoo relay (backend/deploy/yupoo-proxy.conf), then direct Yupoo.
const String kPhotos = 'https://api.tchipa.co.uk/t2';
// Bump when photos are rewritten on the VPS (e.g. tools/jmdy_patch.py) so caches refetch.
const String kPhotosVersion = '2';
const String kPhotoRelay = 'https://api.tchipa.co.uk/yupoo';

const Color kCyan = Color(0xFF00D4FF);
const Color kViolet = Color(0xFF8B5CF6);
const Color kBg = Color(0xFF0D1117);
const Color kSurface = Color(0xFF0F1923);
const Color kCard = Color(0xFF1A2332);
const Color kBorder = Color(0xFF2A3347);
const LinearGradient kGradient = LinearGradient(colors: [kCyan, kViolet]);

// ============================================
// MODELS
// ============================================
class Product {
  final String id;
  final String title;
  final String category;
  final double price;
  final String store;
  final int photoCount; // photos on the VPS
  final List<String> photos; // photo.yupoo.com hashes (fallback, first few only)
  final String code;
  final String _search;

  Product({
    required this.id,
    required this.title,
    required this.category,
    required this.price,
    required this.store,
    required this.photoCount,
    required this.photos,
    required this.code,
  }) : _search = _fold('$title $code $category');

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'] as String,
        title: j['t'] as String,
        category: j['c'] as String,
        price: (j['p'] as num).toDouble(),
        store: j['s'] as String,
        photoCount: j['n'] as int,
        photos: (j['i'] as List).cast<String>(),
        code: (j['code'] as String?) ?? '',
      );

  String get priceLabel => formatUsd(price);

  // source 0 = VPS (s.webp = 400 px cover for the grid, n.webp ≤ 1200 px),
  // 1 = Yupoo relay, 2 = direct Yupoo (small.jpg ≈ 300 px, medium.jpg ≈ 800 px).
  // Returns null when that source doesn't have photo i.
  String? photoUrl(int i, {bool large = false, int source = 0}) {
    if (source == 0) return '$kPhotos/$store/$id/${large || i > 0 ? i + 1 : 's'}.webp?v=$kPhotosVersion';
    if (i >= photos.length) return null;
    return '${source == 2 ? 'https://photo.yupoo.com' : kPhotoRelay}/$store/${photos[i]}/${large ? 'medium' : 'small'}.jpg';
  }

  // Yupoo refuses hotlinked images without a Referer from the store.
  Map<String, String> get imageHeaders => {'Referer': 'https://$store.x.yupoo.com/'};

  bool matches(List<String> terms) => terms.every(_search.contains);
}

String formatUsd(double v) => '\$${v.toStringAsFixed(2)}';

String _fold(String s) {
  const from = 'àâäéèêëîïôöùûüç';
  const to = 'aaaeeeeiioouuuc';
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString();
}

List<Product> _parseCatalog(String raw) =>
    (jsonDecode(raw) as List).map((e) => Product.fromJson(e as Map<String, dynamic>)).toList();

class CartLine {
  final Product product;
  String size;
  int qty;
  CartLine(this.product, {this.size = '', this.qty = 1});
}

// ============================================
// STORE — catalogue, favourites, cart
// ============================================
class Shop extends ChangeNotifier {
  static final Shop i = Shop._();
  Shop._();

  List<Product> products = [];
  List<String> categories = [];
  final Set<String> favorites = {};
  final List<CartLine> cart = [];
  bool loaded = false;
  String? error;

  Future<void> load() async {
    error = null;
    notifyListeners();
    try {
      await _load();
    } catch (e) {
      error = '$e';
      notifyListeners();
    }
  }

  Future<void> _load() async {
    final raw = await rootBundle.loadString('assets/catalog/products.json');
    products = await compute(_parseCatalog, raw);
    final counts = <String, int>{};
    for (final p in products) {
      counts[p.category] = (counts[p.category] ?? 0) + 1;
    }
    categories = counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    final prefs = await SharedPreferences.getInstance();
    favorites.addAll(prefs.getStringList('favorites') ?? []);
    loaded = true;
    notifyListeners();
  }

  Product? byId(String id) {
    for (final p in products) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<void> toggleFavorite(Product p) async {
    favorites.contains(p.id) ? favorites.remove(p.id) : favorites.add(p.id);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorites', favorites.toList());
  }

  void addToCart(Product p, String size) {
    for (final l in cart) {
      if (l.product.id == p.id && l.size == size) {
        l.qty++;
        notifyListeners();
        return;
      }
    }
    cart.add(CartLine(p, size: size));
    notifyListeners();
  }

  void setQty(CartLine l, int qty) {
    if (qty <= 0) {
      cart.remove(l);
    } else {
      l.qty = qty;
    }
    notifyListeners();
  }

  int get cartCount => cart.fold(0, (n, l) => n + l.qty);
  double get cartTotal => cart.fold(0.0, (t, l) => t + l.product.price * l.qty);
}

// ============================================
// ORDER — hand-off to the agent
// ============================================
String orderMessage(List<CartLine> lines) {
  final b = StringBuffer('Bonjour, je souhaite commander sur Tchipa 2 :\n');
  for (final l in lines) {
    final p = l.product;
    b.write('\n• ${p.title}');
    if (p.code.isNotEmpty) b.write(' (${p.code})');
    b.write('\n  Réf ${p.id}');
    if (l.size.isNotEmpty) b.write(' · Taille ${l.size}');
    b.write(' · x${l.qty} · ${formatUsd(p.price * l.qty)}');
  }
  final total = lines.fold(0.0, (t, l) => t + l.product.price * l.qty);
  b.write('\n\nTotal : ${formatUsd(total)}');
  return b.toString();
}

Future<void> sendOrder(BuildContext context, List<CartLine> lines) async {
  final msg = orderMessage(lines);
  final messenger = ScaffoldMessenger.of(context);
  if (kAgentWhatsapp.isNotEmpty) {
    final uri = Uri.parse('https://wa.me/$kAgentWhatsapp?text=${Uri.encodeComponent(msg)}');
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
  }
  await Clipboard.setData(ClipboardData(text: msg));
  messenger.showSnackBar(const SnackBar(
    content: Text('Commande copiée — collez-la dans la conversation avec l\'agent.'),
    duration: Duration(seconds: 4),
  ));
  await launchUrl(Uri.parse(kAgentTelegram), mode: LaunchMode.externalApplication);
}

// ============================================
// APP
// ============================================
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  Shop.i.load();
  runApp(const Tchipa2App());
}

class Tchipa2App extends StatelessWidget {
  const Tchipa2App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Tchipa 2',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        primaryColor: kCyan,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kCyan,
          brightness: Brightness.dark,
          surface: kSurface,
          primary: kCyan,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: kSurface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: kCyan),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          hintStyle: const TextStyle(color: Colors.white38),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: kCard,
          contentTextStyle: TextStyle(color: Colors.white),
        ),
      ),
      home: const RootScreen(),
    );
  }
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});
  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Shop.i,
      builder: (context, _) => Scaffold(
        body: IndexedStack(
          index: _tab,
          children: const [ShopScreen(), FavoritesScreen(), CartScreen()],
        ),
        bottomNavigationBar: NavigationBar(
          backgroundColor: kSurface,
          indicatorColor: kCyan.withValues(alpha: 0.15),
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.storefront_outlined),
              selectedIcon: Icon(Icons.storefront, color: kCyan),
              label: 'Boutique',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: Shop.i.favorites.isNotEmpty,
                label: Text('${Shop.i.favorites.length}'),
                child: const Icon(Icons.favorite_border),
              ),
              selectedIcon: const Icon(Icons.favorite, color: kCyan),
              label: 'Favoris',
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: Shop.i.cartCount > 0,
                label: Text('${Shop.i.cartCount}'),
                child: const Icon(Icons.shopping_bag_outlined),
              ),
              selectedIcon: const Icon(Icons.shopping_bag, color: kCyan),
              label: 'Panier',
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================
// SHOP SCREEN
// ============================================
enum SortMode { relevance, priceAsc, priceDesc }

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});
  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  final _search = TextEditingController();
  String _category = '';
  SortMode _sort = SortMode.relevance;

  List<Product> _visible() {
    final terms = _fold(_search.text.trim()).split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final list = Shop.i.products
        .where((p) => (_category.isEmpty || p.category == _category) && p.matches(terms))
        .toList();
    if (_sort == SortMode.priceAsc) list.sort((a, b) => a.price.compareTo(b.price));
    if (_sort == SortMode.priceDesc) list.sort((a, b) => b.price.compareTo(a.price));
    return list;
  }

  @override
  void initState() {
    super.initState();
    // The tabs are const children of an IndexedStack, so they don't rebuild
    // with RootScreen: listen to the shop directly.
    Shop.i.addListener(_onShop);
  }

  void _onShop() => setState(() {});

  @override
  void dispose() {
    Shop.i.removeListener(_onShop);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shop = Shop.i;
    if (shop.error != null) {
      return _Empty(
        icon: Icons.error_outline,
        text: 'Catalogue indisponible.\n${shop.error}',
        action: TextButton(onPressed: shop.load, child: const Text('Réessayer')),
      );
    }
    if (!shop.loaded) {
      return const Center(child: CircularProgressIndicator(color: kCyan));
    }
    final items = _visible();
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(child: _header(items.length)),
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedBar(
              height: 120,
              child: Container(
                color: kBg,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(children: [
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: Colors.white),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: 'Rechercher (Jordan, Moncler, CT8012…)',
                          prefixIcon: const Icon(Icons.search, color: Colors.white38),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close, color: Colors.white38),
                                  onPressed: () => setState(_search.clear),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _sortButton(),
                  ]),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 36,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _chip('Tout', ''),
                        for (final c in shop.categories) _chip(c, c),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          ),
          if (items.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text('Aucun article ne correspond.', style: TextStyle(color: Colors.white54)),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.66,
                ),
                itemCount: items.length,
                itemBuilder: (_, i) => ProductCard(product: items[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(int count) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset('assets/tchipa_logo.png', width: 38, height: 38),
          ),
          const SizedBox(width: 10),
          ShaderMask(
            shaderCallback: (r) => kGradient.createShader(r),
            child: const Text('TCHIPA 2',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: Colors.white)),
          ),
          const Spacer(),
          Text('$count articles', style: const TextStyle(color: Colors.white54, fontSize: 13)),
        ]),
      );

  Widget _chip(String label, String value) {
    final selected = _category == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => setState(() => _category = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: selected ? kGradient : null,
            color: selected ? null : kSurface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: selected ? Colors.transparent : kBorder),
          ),
          child: Text(label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white70,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                fontSize: 13,
              )),
        ),
      ),
    );
  }

  Widget _sortButton() => PopupMenuButton<SortMode>(
        tooltip: 'Trier',
        color: kCard,
        initialValue: _sort,
        onSelected: (m) => setState(() => _sort = m),
        itemBuilder: (_) => const [
          PopupMenuItem(value: SortMode.relevance, child: Text('Pertinence')),
          PopupMenuItem(value: SortMode.priceAsc, child: Text('Prix croissant')),
          PopupMenuItem(value: SortMode.priceDesc, child: Text('Prix décroissant')),
        ],
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(14)),
          child: Icon(Icons.swap_vert, color: _sort == SortMode.relevance ? Colors.white54 : kCyan),
        ),
      );
}

class _PinnedBar extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;
  _PinnedBar({required this.height, required this.child});

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => child;
  @override
  bool shouldRebuild(_PinnedBar old) => true;
}

// ============================================
// WIDGETS
// ============================================
class YupooImage extends StatelessWidget {
  final Product product;
  final int index;
  final bool large;
  final BoxFit fit;
  const YupooImage({super.key, required this.product, this.index = 0, this.large = false, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) => _image(context, 0);

  // VPS first; on failure the Yupoo relay, then straight from Yupoo, then a placeholder.
  Widget _image(BuildContext context, int source) {
    final url = source > 2 ? null : product.photoUrl(index, large: large, source: source);
    if (url == null) {
      return Container(
        color: kCard,
        alignment: Alignment.center,
        child: const Icon(Icons.image_not_supported_outlined, color: Colors.white24),
      );
    }
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: source == 2 ? product.imageHeaders : null,
      fit: fit,
      memCacheWidth: large ? null : (220 * dpr).round(),
      fadeInDuration: const Duration(milliseconds: 150),
      placeholder: (_, __) => Container(color: kCard),
      errorWidget: (context, __, ___) => _image(context, source + 1),
    );
  }
}

class ProductCard extends StatelessWidget {
  final Product product;
  const ProductCard({super.key, required this.product});

  @override
  Widget build(BuildContext context) {
    final fav = Shop.i.favorites.contains(product.id);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProductScreen(product: product)),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              Hero(tag: 'p${product.id}', child: YupooImage(product: product)),
              Positioned(
                top: 6,
                right: 6,
                child: GestureDetector(
                  onTap: () => Shop.i.toggleFavorite(product),
                  child: CircleAvatar(
                    radius: 15,
                    backgroundColor: Colors.black45,
                    child: Icon(fav ? Icons.favorite : Icons.favorite_border,
                        size: 17, color: fav ? Colors.pinkAccent : Colors.white),
                  ),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(product.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3, fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              Text(product.priceLabel,
                  style: const TextStyle(color: kCyan, fontSize: 16, fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class GradientButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  const GradientButton({super.key, required this.label, required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: Material(
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: const BoxDecoration(gradient: kGradient),
          child: InkWell(
            onTap: onPressed,
            child: SizedBox(
              height: 54,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: Colors.white),
                const SizedBox(width: 8),
                Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================
// PRODUCT SCREEN
// ============================================
class ProductScreen extends StatefulWidget {
  final Product product;
  const ProductScreen({super.key, required this.product});
  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  final _size = TextEditingController();
  int _page = 0;

  @override
  void dispose() {
    _size.dispose();
    super.dispose();
  }

  void _openZoom(int index) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => PhotoViewerScreen(product: widget.product, initial: index),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    return ListenableBuilder(
      listenable: Shop.i,
      builder: (context, _) {
        final fav = Shop.i.favorites.contains(p.id);
        return Scaffold(
          backgroundColor: kBg,
          body: CustomScrollView(slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: MediaQuery.sizeOf(context).width,
              backgroundColor: kBg,
              actions: [
                IconButton(
                  icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: fav ? Colors.pinkAccent : Colors.white),
                  onPressed: () => Shop.i.toggleFavorite(p),
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                background: Stack(fit: StackFit.expand, children: [
                  PageView.builder(
                    itemCount: p.photoCount,
                    onPageChanged: (i) => setState(() => _page = i),
                    itemBuilder: (_, i) => GestureDetector(
                      onTap: () => _openZoom(i),
                      child: i == 0
                          ? Hero(tag: 'p${p.id}', child: YupooImage(product: p, large: true))
                          : YupooImage(product: p, index: i, large: true),
                    ),
                  ),
                  if (p.photoCount > 1)
                    Positioned(
                      bottom: 12,
                      left: 0,
                      right: 0,
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        for (var i = 0; i < p.photoCount; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: i == _page ? 18 : 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: i == _page ? kCyan : Colors.white54,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                      ]),
                    ),
                ]),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              sliver: SliverList.list(children: [
                Text(p.category.toUpperCase(),
                    style: const TextStyle(color: kCyan, fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(p.title,
                    style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w700, height: 1.3)),
                const SizedBox(height: 6),
                Text(p.code.isEmpty ? 'Réf ${p.id}' : '${p.code} · Réf ${p.id}',
                    style: const TextStyle(color: Colors.white38, fontSize: 13)),
                const SizedBox(height: 18),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  ShaderMask(
                    shaderCallback: (r) => kGradient.createShader(r),
                    child: Text(p.priceLabel,
                        style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 8),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Text('USD', style: TextStyle(color: Colors.white38, fontSize: 13)),
                  ),
                ]),
                const SizedBox(height: 22),
                TextField(
                  controller: _size,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Taille / pointure',
                    hintText: 'ex. 42, M, 8 ans',
                    prefixIcon: Icon(Icons.straighten, color: Colors.white38),
                  ),
                ),
                const SizedBox(height: 18),
                GradientButton(
                  label: 'Commander',
                  icon: Icons.send_rounded,
                  onPressed: () => sendOrder(context, [CartLine(p, size: _size.text.trim())]),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    side: const BorderSide(color: kBorder),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: const Icon(Icons.add_shopping_cart),
                  label: const Text('Ajouter au panier'),
                  onPressed: () {
                    Shop.i.addToCart(p, _size.text.trim());
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Ajouté au panier'), duration: Duration(seconds: 2)),
                    );
                  },
                ),
                const SizedBox(height: 24),
                const _InfoRow(icon: Icons.photo_library_outlined, text: 'Touchez une photo pour l\'agrandir.'),
                const _InfoRow(icon: Icons.support_agent, text: 'Un agent confirme la taille, la disponibilité et la livraison avant paiement.'),
                const _InfoRow(icon: Icons.payments_outlined, text: 'Paiement en dinars ou en dollars via l\'agent.'),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: Colors.white38),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.4))),
        ]),
      );
}

class PhotoViewerScreen extends StatelessWidget {
  final Product product;
  final int initial;
  const PhotoViewerScreen({super.key, required this.product, required this.initial});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: PageView.builder(
        controller: PageController(initialPage: initial),
        itemCount: product.photoCount,
        itemBuilder: (_, i) => InteractiveViewer(
          maxScale: 5,
          child: Center(child: YupooImage(product: product, index: i, large: true, fit: BoxFit.contain)),
        ),
      ),
    );
  }
}

// ============================================
// FAVORITES SCREEN
// ============================================
class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: Shop.i, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final items = Shop.i.favorites.map(Shop.i.byId).whereType<Product>().toList();
    return SafeArea(
      bottom: false,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _ScreenTitle('Favoris'),
        Expanded(
          child: items.isEmpty
              ? const _Empty(icon: Icons.favorite_border, text: 'Touchez le cœur d\'un article pour le retrouver ici.')
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.66,
                  ),
                  itemCount: items.length,
                  itemBuilder: (_, i) => ProductCard(product: items[i]),
                ),
        ),
      ]),
    );
  }
}

// ============================================
// CART SCREEN
// ============================================
class CartScreen extends StatelessWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: Shop.i, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final shop = Shop.i;
    return SafeArea(
      bottom: false,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _ScreenTitle('Panier'),
        Expanded(
          child: shop.cart.isEmpty
              ? const _Empty(icon: Icons.shopping_bag_outlined, text: 'Votre panier est vide.')
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: shop.cart.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _CartTile(line: shop.cart[i]),
                ),
        ),
        if (shop.cart.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            decoration: const BoxDecoration(
              color: kSurface,
              border: Border(top: BorderSide(color: kBorder)),
            ),
            child: Column(children: [
              Row(children: [
                const Text('Total', style: TextStyle(color: Colors.white70, fontSize: 16)),
                const Spacer(),
                Text(formatUsd(shop.cartTotal),
                    style: const TextStyle(color: kCyan, fontSize: 22, fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 12),
              GradientButton(
                label: 'Commander le panier',
                icon: Icons.send_rounded,
                onPressed: () => sendOrder(context, List.of(shop.cart)),
              ),
            ]),
          ),
      ]),
    );
  }
}

class _CartTile extends StatelessWidget {
  final CartLine line;
  const _CartTile({required this.line});

  @override
  Widget build(BuildContext context) {
    final p = line.product;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(width: 72, height: 72, child: YupooImage(product: p)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(line.size.isEmpty ? 'Taille à préciser' : 'Taille ${line.size}',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 4),
            Text(formatUsd(p.price * line.qty),
                style: const TextStyle(color: kCyan, fontWeight: FontWeight.w700)),
          ]),
        ),
        Column(children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_circle_outline, color: Colors.white70),
            onPressed: () => Shop.i.setQty(line, line.qty + 1),
          ),
          Text('${line.qty}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(line.qty == 1 ? Icons.delete_outline : Icons.remove_circle_outline, color: Colors.white70),
            onPressed: () => Shop.i.setQty(line, line.qty - 1),
          ),
        ]),
      ]),
    );
  }
}

class _ScreenTitle extends StatelessWidget {
  final String text;
  const _ScreenTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
      );
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;
  const _Empty({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 48, color: Colors.white24),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54)),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ]),
        ),
      );
}
