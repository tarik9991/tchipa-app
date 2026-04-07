import 'dart:ui';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:screenshot/screenshot.dart';

void main() => runApp(const TchipaApp());

class TchipaApp extends StatelessWidget {
  const TchipaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D1B2A),
        primaryColor: const Color(0xFF00B4D8),
      ),
      home: const CalculatorScreen(),
    );
  }
}

class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key});
  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  final TextEditingController _linkController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();
  final ScreenshotController _screenshotController = ScreenshotController();
  
  bool _isLoading = false;
  double _originalPrice = 0.0;
  double _totalUsdt = 0.0;
  double _totalDzd = 0.0;
  String _orderID = "";
  final double _exchangeRate = 242.0;

  // --- SCRAPER (Appel à ton VPS) ---
  Future<void> _fetchPriceFromScraper() async {
    String url = _linkController.text.trim();
    if (url.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      // REMPLACE "YOUR_SERVER_IP_HERE" PAR L'IP DE TON SERVEUR
      final response = await http.get(Uri.parse('http://YOUR_SERVER_IP_HERE:3000/get-price?url=$url'))
          .timeout(const Duration(seconds: 25));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _priceController.text = data['originalPrice'].toString();
          _calculate();
        });
      }
    } catch (e) {
      _showToast("Erreur VPS : Vérifiez l'IP et si le serveur est bien lancé.");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _calculate() {
    setState(() {
      _originalPrice = double.tryParse(_priceController.text) ?? 0.0;
      _totalUsdt = _originalPrice * 1.25;
      _totalDzd = _totalUsdt * _exchangeRate;
      _orderID = "TC-${Random().nextInt(9000) + 1000}";
    });
  }

  // --- LOGIQUE PARTAGE (Corrigée pour le Web) ---
  Future<void> _shareCoupon() async {
    final image = await _screenshotController.capture();
    if (image != null) {
      // On ne crée plus de fichier, on partage les données de l'image directement.
      await Share.shareXFiles(
        [XFile.fromData(image, name: 'coupon.png', mimeType: 'image/png')],
        text: 'Commande Tchipa $_orderID',
      );
    }
  }

  void _showCouponDialog() {
    showDialog(
      context: context,
      builder: (context) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: AlertDialog(
          backgroundColor: const Color(0xFF1B263B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Screenshot(
                controller: _screenshotController,
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(15),
                  child: QrImageView(
                    data: "TCHIPA-PAY|$_orderID|${_totalUsdt.toStringAsFixed(2)}",
                    version: QrVersions.auto,
                    size: 180.0,
                  ),
                ),
              ),
              const SizedBox(height: 15),
              Text("ID: $_orderID", style: const TextStyle(color: Color(0xFF00B4D8), fontWeight: FontWeight.bold)),
              Text("${_totalUsdt.toStringAsFixed(2)} USDT", style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Fermer")),
            ElevatedButton.icon(
              onPressed: _shareCoupon,
              icon: const Icon(Icons.share),
              label: const Text("Partager"),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00B4D8)),
            ),
          ],
        ),
      ),
    );
  }

  void _showToast(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(25),
          child: Column(
            children: [
              const SizedBox(height: 10),
              const Text("Tchipa 🚀", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 30),
              _buildInputCard(),
              const SizedBox(height: 30),
              if (_totalUsdt > 0) _buildResultCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(25)),
      child: Column(
        children: [
          TextField(
            controller: _linkController,
            decoration: InputDecoration(
              hintText: "Lien produit",
              suffixIcon: IconButton(
                icon: _isLoading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_fix_high, color: Color(0xFF00B4D8)),
                onPressed: _fetchPriceFromScraper,
              ),
            ),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: _priceController,
            keyboardType: TextInputType.number,
            onChanged: (v) => _calculate(),
            decoration: const InputDecoration(hintText: "Prix (\$)", prefixIcon: Icon(Icons.attach_money)),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(25),
          decoration: BoxDecoration(
            color: const Color(0xFF00B4D8).withOpacity(0.1),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            children: [
              _resLine("TOTAL USDT", _totalUsdt.toStringAsFixed(2), true),
              const Divider(height: 30),
              _resLine("ESTIMATION DZD", "${_totalDzd.toStringAsFixed(0)} DA", true, color: const Color(0xFF00B4D8)),
            ],
          ),
        ),
        const SizedBox(height: 25),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _showCouponDialog,
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00B4D8), padding: const EdgeInsets.all(18), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
            child: const Text("GÉNÉRER LE COUPON", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
          ),
        ),
      ],
    );
  }

  Widget _resLine(String l, String v, bool bold, {Color? color}) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(l, style: const TextStyle(color: Colors.white70)),
      Text(v, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color ?? Colors.white)),
    ],
  );
}