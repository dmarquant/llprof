#pragma once

#include <QWidget>
#include <QTreeView>
#include <QVBoxLayout>
#include <QHeaderView>
#include "FunctionListModel.h"


class FunctionList : public QWidget {
  Q_OBJECT

  FunctionListModel* model = nullptr;

public:
  FunctionList(QWidget* parent = nullptr) : QWidget(parent) {
    setMinimumSize(720, 600);

    model = new FunctionListModel(this);

    QVBoxLayout* layout = new QVBoxLayout(this);

    QTreeView* treeView = new QTreeView(this);
    treeView->setModel(model);
    treeView->setRootIsDecorated(false);

    treeView->header()->setSectionResizeMode(0, QHeaderView::Interactive);
    treeView->header()->setSectionResizeMode(1, QHeaderView::Fixed);
    treeView->header()->setSectionResizeMode(2, QHeaderView::Fixed);

    treeView->setColumnWidth(0, 400);
    treeView->setColumnWidth(1, 80);
    treeView->setColumnWidth(2, 80);

    treeView->setSortingEnabled(true);

    layout->addWidget(treeView);
  }

  void setSampleData(Samples* samples) {
    model->setSampleData(samples);
  }
};

