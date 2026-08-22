#include <QByteArray>
#include <QDebug>
#include <QFile>

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

struct SampleCount {
  uint64_t exclusive = 0;
  uint64_t inclusive = 0;
};

QString toString(const QByteArray& stringTable, const Location& loc) {
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

int main(int argc, char** argv) {
  QFile file("samples.bin");
  if (!file.open(QIODeviceBase::ReadOnly)) {
    qDebug() << "Failed to open samples";
    return -1;
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
      return -1;
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

  QHash<uint32_t, SampleCount> sampleCounts;

  int loci = 0;
  for (const Sample& sample : samples) {
    int locend = loci + sample.numFrames - 1;
    for (; locend >= loci; locend--) {
      uint32_t loc_ix = locations[locend];
      auto& entry = sampleCounts[loc_ix];
      if (locend == loci) {
        entry.exclusive++;
      }
      entry.inclusive++;
    }
      
    loci += sample.numFrames;
  }

  for (auto entry = sampleCounts.cbegin(), end = sampleCounts.cend(); entry != end; ++entry) {
    Location loc = locationTable[entry.key()];
    SampleCount count = entry.value();
    qDebug() << count.exclusive << count.inclusive << toString(stringTable, loc);
  }
}
