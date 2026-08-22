#pragma once

#include <QAbstractTableModel>
#include <QHash>

struct SampleCount {
  uint32_t location = 0;
  uint64_t exclusive = 0;
  uint64_t inclusive = 0;
};

QHash<uint32_t, SampleCount> computeSampleCounts(const Samples& samples) {
  QHash<uint32_t, SampleCount> sampleCounts;

  int loci = 0;
  for (const Sample& sample : samples.samples) {
    int locend = loci + sample.numFrames - 1;
    for (; locend >= loci; locend--) {
      uint32_t loc_ix = samples.locations[locend];
      auto& entry = sampleCounts[loc_ix];
      entry.location = loc_ix;
      if (locend == loci) {
        entry.exclusive++;
      }
      entry.inclusive++;
    }
      
    loci += sample.numFrames;
  }
  return sampleCounts;
}


class FunctionListModel : public QAbstractTableModel {
  Q_OBJECT

  Samples* samples;
  QVector<SampleCount> sampleCounts;
  uint64_t totalCount;

public:
  explicit FunctionListModel(QObject* parent = nullptr) : QAbstractTableModel(parent) {}

  void setSampleData(Samples* samples) {
    this->samples = samples;

    beginResetModel();
    auto counts = computeSampleCounts(*samples);
    sampleCounts = counts.values();

    totalCount = 0;
    for (auto sc : sampleCounts) {
      totalCount += sc.inclusive;
    }

    endResetModel();
  }

  int rowCount(const QModelIndex& parent = QModelIndex()) const override {
    if (parent.isValid()) return 0;
    return sampleCounts.size();
  }

  int columnCount(const QModelIndex& parent = QModelIndex()) const override {
    if (parent.isValid()) return 0;
    return 3;
  }

  QVariant data(const QModelIndex& index, int role = Qt::DisplayRole) const override {
    if (!index.isValid() || role != Qt::DisplayRole) 
      return QVariant();

    SampleCount sc = sampleCounts[index.row()];
    if (index.column() == 0) {
      return samples->locationToString(sc.location);
    } else if (index.column() == 1) {
      //return QString("%1").arg(((double)sc.inclusive / (double)totalCount) * 100.0, 0, 'f', 2);
      return (quint64)sc.inclusive;
    } else if (index.column() == 2) {
      //return QString("%1").arg(((double)sc.exclusive / (double)totalCount) * 100.0, 0, 'f', 2);
      return (quint64)sc.exclusive;
    }
    return QVariant();
  }

  QVariant headerData(int section, Qt::Orientation orientation, int role = Qt::DisplayRole) const override {
    if (role != Qt::DisplayRole || orientation != Qt::Horizontal)
        return QVariant();

    switch (section) {
        case 0: return QStringLiteral("Location");
        case 1: return QStringLiteral("Inclusive");
        case 2: return QStringLiteral("Exclusive");
        default: return QVariant();
    }
  }

  void sort(int column, Qt::SortOrder order = Qt::AscendingOrder) override {
    beginResetModel();

    std::sort(sampleCounts.begin(), sampleCounts.end(), [this, column, order] (const SampleCount& a, const SampleCount& b) {
        bool isAsc = (order == Qt::AscendingOrder);
        switch (column) {
        case 0: return isAsc ? (samples->locationToString(a.location) < samples->locationToString(b.location)) : (samples->locationToString(a.location) > samples->locationToString(b.location));
        case 1: return isAsc ? (a.inclusive < b.inclusive) : (a.inclusive > b.inclusive);
        case 2: return isAsc ? (a.exclusive < b.exclusive) : (a.exclusive > b.exclusive);
        default: return false;
        }
    });

    endResetModel();
  }
};


