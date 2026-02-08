// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'product_hive.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ProductHiveAdapter extends TypeAdapter<ProductHive> {
  @override
  final int typeId = 1;

  @override
  ProductHive read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ProductHive(
      id: fields[0] as String,
      name: fields[1] as String,
      localMediaPath: fields[2] as String?,
      price: fields[3] as double,
      isVideo: fields[4] as bool,
      latitude: fields[5] as double?,
      longitude: fields[6] as double?,
      isPromo: fields[7] as bool,
      isTrending: fields[8] as bool,
      updatedAt: fields[9] as int?,
    );
  }

  @override
  void write(BinaryWriter writer, ProductHive obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.localMediaPath)
      ..writeByte(3)
      ..write(obj.price)
      ..writeByte(4)
      ..write(obj.isVideo)
      ..writeByte(5)
      ..write(obj.latitude)
      ..writeByte(6)
      ..write(obj.longitude)
      ..writeByte(7)
      ..write(obj.isPromo)
      ..writeByte(8)
      ..write(obj.isTrending)
      ..writeByte(9)
      ..write(obj.updatedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProductHiveAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
