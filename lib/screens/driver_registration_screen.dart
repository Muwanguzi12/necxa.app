import 'package:flutter/material.dart';
import '../theme.dart';
import '../app_state.dart';
import '../models/transport_models.dart';

class DriverRegistrationScreen extends StatefulWidget {
  final AppState state;
  const DriverRegistrationScreen({super.key, required this.state});

  @override
  State<DriverRegistrationScreen> createState() => _DriverRegistrationScreenState();
}

class _DriverRegistrationScreenState extends State<DriverRegistrationScreen> {
  int _step = 0;
  final _nameController = TextEditingController();
  final _plateController = TextEditingController();
  VehicleType _selectedType = VehicleType.bike;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: C.text),
          onPressed: () => _step == 0 ? widget.state.go('transport') : setState(() => _step--),
        ),
        title: Text('MISSION ENROLLMENT', style: syne(sz: 14, w: FontWeight.w700)),
        centerTitle: true,
      ),
      body: Column(
        children: [
          _buildProgressBar(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: _buildStepContent(),
            ),
          ),
          _buildBottomAction(),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    return Container(
      height: 4,
      width: double.infinity,
      color: C.cardDk,
      child: Row(
        children: [
          Expanded(flex: _step + 1, child: Container(color: C.brand)),
          Expanded(flex: 3 - (_step + 1), child: const SizedBox()),
        ],
      ),
    );
  }

  Widget _buildStepContent() {
    switch (_step) {
      case 0: return _stepPersonalDetails();
      case 1: return _stepVehicleDetails();
      case 2: return _stepDocuments();
      default: return const SizedBox();
    }
  }

  Widget _stepPersonalDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 1: Personal Details', style: syne(sz: 18, c: C.brand)),
        const SizedBox(height: 8),
        Text('We need some basic info to get you started.', style: dm(sz: 13, c: C.dim)),
        const SizedBox(height: 32),
        _inputField('Full Name', '??', _nameController),
        const SizedBox(height: 16),
        _inputField('Email', '??', TextEditingController(text: widget.state.user?.email ?? ''), enabled: false),
      ],
    );
  }

  Widget _stepVehicleDetails() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 2: Vehicle Details', style: syne(sz: 18, c: C.brand)),
        const SizedBox(height: 8),
        Text('What will you be driving?', style: dm(sz: 13, c: C.dim)),
        const SizedBox(height: 32),
        Text('Vehicle Type', style: syne(sz: 14)),
        const SizedBox(height: 12),
        Row(
          children: VehicleType.values.map((t) => _typeOption(t)).toList(),
        ),
        const SizedBox(height: 32),
        _inputField('Number Plate', '??', _plateController),
      ],
    );
  }

  Widget _stepDocuments() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Step 3: Upload Documents', style: syne(sz: 18, c: C.brand)),
        const SizedBox(height: 8),
        Text('Upload your valid driving permit to get verified.', style: dm(sz: 13, c: C.dim)),
        const SizedBox(height: 32),
        GestureDetector(
          onTap: () => widget.state.pickMedia(),
          child: Container(
            width: double.infinity,
            height: 200,
            decoration: BoxDecoration(
              color: C.cardDk,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: C.border, style: BorderStyle.none),
            ),
            child: widget.state.pickedMedia == null
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.upload_file, color: C.brand, size: 40),
                    const SizedBox(height: 12),
                    Text('Click to upload Permit', style: syne(sz: 13, c: C.brand)),
                  ],
                )
              : ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.file(widget.state.pickedMedia!, fit: BoxFit.cover),
                ),
          ),
        ),
      ],
    );
  }

  Widget _inputField(String label, String icon, TextEditingController ctrl, {bool enabled = true}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: syne(sz: 12, c: C.dim)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.border),
          ),
          child: Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: ctrl,
                  enabled: enabled,
                  style: dm(sz: 14),
                  decoration: const InputDecoration(border: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _typeOption(VehicleType type) {
    bool active = _selectedType == type;
    String emoji = type == VehicleType.bike ? '???' : type == VehicleType.van ? '??' : '??';
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedType = type),
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: active ? C.brand.withOpacity(.1) : C.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: active ? C.brand : C.border),
          ),
          child: Column(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(height: 6),
              Text(type.name.toUpperCase(), style: dm(sz: 9, w: FontWeight.w700, c: active ? C.brand : C.dim)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomAction() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: C.card, border: Border(top: BorderSide(color: C.border))),
      child: widget.state.isTransportLoading
        ? Center(child: CircularProgressIndicator(color: C.brand))
        : GestureDetector(
            onTap: _onNext,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(color: C.brand, borderRadius: BorderRadius.circular(12)),
              child: Text(_step == 2 ? 'SUBMIT APPLICATION' : 'CONTINUE', textAlign: TextAlign.center, 
                style: syne(sz: 14, c: C.text, w: FontWeight.w700)),
            ),
          ),
    );
  }

  void _onNext() {
    if (_step < 2) {
      setState(() => _step++);
    } else {
      widget.state.registerDriver({
        'name': _nameController.text,
        'number_plate': _plateController.text,
        'vehicle_type': _selectedType.name,
      });
    }
  }
}


