#include <QByteArray>
#include <QDebug>
#include <QFile>
#include <QApplication>

struct StringTableEntry {
  uint32_t offset;
  uint32_t len;
};

enum LocationType: uint8_t {
  Address,
  ElfFile,
  Symbol
};

struct Location {
  LocationType type;
  union {
    uint64_t address;
    struct {
      StringTableEntry name;
      uint64_t offset;
    } elfFile;
    struct {
      StringTableEntry fileName;
      StringTableEntry name;
    } symbol;
  };
};

struct Sample {
  uint64_t time_ns;
  uint32_t cpu;
  uint32_t tid;
  uint32_t numFrames;
};

struct Samples {
  QByteArray stringTable;
  QVector<Location> locationTable;
  QVector<Sample> samples;
  QVector<uint32_t> locations;

  QString locationToString(uint32_t ix) {
    Location loc = locationTable[ix];
    if (loc.type == Address) {
      return QString("0x%1").arg(loc.address, 0, 16);
    } else if (loc.type == ElfFile) {
      auto name = stringTable.sliced(loc.elfFile.name.offset, loc.elfFile.name.len);
      return QString("%1@%2").arg(name).arg(loc.elfFile.offset, 0, 16);
      qDebug() << ' ' << name << '@' << loc.elfFile.offset;
    } else if (loc.type == Symbol) {
      auto fileName = stringTable.sliced(loc.symbol.fileName.offset, loc.symbol.fileName.len);
      auto name = stringTable.sliced(loc.symbol.name.offset, loc.symbol.name.len);
      return QString("%1:%2").arg(fileName).arg(name);
    } else {
      return QString("Invalid location");
    }
  }
};

Samples loadSamples(const QString& fileName) {
  QFile file("samples.bin");
  if (!file.open(QIODeviceBase::ReadOnly)) {
    qDebug() << "Failed to open samples";
    exit(-1);
  }

  QDataStream stream(&file);
  stream.setByteOrder(QDataStream::LittleEndian);

  quint16 major, minor;
  stream >> major >> minor;

  quint32 stringTableBytes, locationTableLength;
  quint64 numSamples, numLocations;
  stream >> stringTableBytes >> locationTableLength >> numSamples >> numLocations;

  QByteArray stringTable(stringTableBytes, '\0');
  stream.readRawData(stringTable.data(), stringTable.size());

  QList<Location> locationTable(locationTableLength, Qt::Uninitialized);
  for (Location& location : locationTable) {
    stream >> location.type;
    if (location.type == Address) {
      stream >> (quint64&)location.address;
    } else if (location.type == ElfFile) {
      stream >> location.elfFile.name.offset;
      stream >> location.elfFile.name.len;
      stream >> (quint64&)location.elfFile.offset;
    } else if (location.type == Symbol) {
      stream >> location.symbol.fileName.offset;
      stream >> location.symbol.fileName.len;
      stream >> location.symbol.name.offset;
      stream >> location.symbol.name.len;
    } else {
      qDebug() << "Unexpected location type!" << location.type;
      exit(-1);
    }
  }

  QVector<Sample> samples(numSamples, Qt::Uninitialized);
  for (Sample& sample : samples) {
    stream >> (quint64&)sample.time_ns >> sample.cpu >> sample.tid >> sample.numFrames;
  }

  QVector<uint32_t> locations(numLocations, 0);
  for (uint32_t& loc : locations) {
    stream >> loc;
  }

  Samples loaded;
  loaded.stringTable = std::move(stringTable);
  loaded.locationTable = std::move(locationTable);
  loaded.samples = std::move(samples);
  loaded.locations = std::move(locations);
  return loaded;
}

#include "FunctionListModel.h"
#include "FunctionList.h"

int main(int argc, char** argv) {
  Samples samples = loadSamples("samples.bin");

  QApplication app(argc, argv);

  FunctionList list;
  list.setSampleData(&samples);
  list.show();

  return app.exec();
}

#include "moc.cpp"
