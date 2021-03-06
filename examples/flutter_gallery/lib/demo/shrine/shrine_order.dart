// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:flutter/material.dart';

import '../shrine_demo.dart' show ShrinePageRoute;
import 'shrine_page.dart';
import 'shrine_theme.dart';
import 'shrine_types.dart';

/// Describes a product and vendor in detail, supports specifying
/// a order quantity (0-5). Appears at the top of the OrderPage.
class OrderItem extends StatelessWidget {
  OrderItem({ Key key, this.product, this.quantity, this.quantityChanged }) : super(key: key) {
    assert(product != null);
    assert(quantity != null && quantity >= 0 && quantity <= 5);
  }

  final Product product;
  final int quantity;
  final ValueChanged<int> quantityChanged;

  @override
  Widget build(BuildContext context) {
    final ShrineTheme theme = ShrineTheme.of(context);
    return new Material(
      type: MaterialType.card,
      elevation: 0,
      child: new Padding(
        padding: const EdgeInsets.only(left: 16.0, top: 18.0, right: 16.0, bottom: 24.0),
        child: new Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            new Padding(
              padding: const EdgeInsets.only(left: 56.0),
              child: new SizedBox(
                width: 248.0,
                height: 248.0,
                child: new Hero(
                  tag: productHeroTag,
                  child: new NetworkImage(
                    fit: ImageFit.contain,
                    src: product.imageUrl
                  )
                )
              )
            ),
            new SizedBox(height: 24.0),
            new Row(
              children: <Widget>[
                new Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: new Center(
                    child: new Icon(
                      icon: Icons.info_outline,
                      size: 24.0,
                      color: const Color(0xFFFFE0E0)
                    )
                  )
                ),
                new Flexible(
                  child: new Text(product.name, style: theme.featureTitleStyle)
                )
              ]
            ),
            new Padding(
              padding: const EdgeInsets.only(left: 56.0),
              child: new Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  new SizedBox(height: 24.0),
                  new Text(product.description, style: theme.featureStyle),
                  new SizedBox(height: 16.0),
                  new Padding(
                    padding: const EdgeInsets.only(top: 8.0, bottom: 8.0, right: 88.0),
                    child: new DropDownButtonHideUnderline(
                      child: new Container(
                        decoration: new BoxDecoration(
                          border: new Border.all(
                            color: const Color(0xFFD9D9D9)
                          )
                        ),
                        child: new DropDownButton<int>(
                          items: <int>[0, 1, 2, 3, 4, 5].map((int value) {
                            return new DropDownMenuItem<int>(
                              value: value,
                              child: new Text('Quantity $value', style: theme.quantityMenuStyle)
                            );
                          }).toList(),
                          value: quantity,
                          onChanged: quantityChanged
                        )
                      )
                    )
                  ),
                  new SizedBox(height: 16.0),
                  new SizedBox(
                    height: 24.0,
                    child: new Align(
                      alignment: FractionalOffset.bottomLeft,
                      child: new Text(product.vendor.name, style: theme.vendorTitleStyle)
                    )
                  ),
                  new SizedBox(height: 16.0),
                  new Text(product.vendor.description, style: theme.vendorStyle),
                  new SizedBox(height: 24.0)
                ]
              )
            )
          ]
        )
      )
    );
  }
}

class OrderPage extends StatefulWidget {
  OrderPage({ Key key, this.order, this.products }) : super(key: key) {
    assert(order != null);
    assert(products != null && products.length > 0);
  }

  final Order order;
  final List<Product> products;

  @override
  _OrderPageState createState() => new _OrderPageState();
}

/// Displays a product's OrderItem above photos of all of the other products
/// arranged in two columns. Enables the user to specify a quantity and add an
/// order to the shopping cart.
class _OrderPageState extends State<OrderPage> {
  final GlobalKey<ScaffoldState> scaffoldKey = new GlobalKey<ScaffoldState>(debugLabel: 'Order Page');

  Order get currentOrder => ShrineOrderRoute.of(context).order;

  set currentOrder(Order value) {
    ShrineOrderRoute.of(context).order = value;
  }

  void updateOrder({ int quantity, bool inCart }) {
    Order newOrder = currentOrder.copyWith(quantity: quantity, inCart: inCart);
    if (currentOrder != newOrder) {
      setState(() {
        currentOrder = newOrder;
      });
    }
  }

  void showSnackBarMessage(String message) {
    scaffoldKey.currentState.showSnackBar(new SnackBar(content: new Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return new ShrinePage(
      scaffoldKey: scaffoldKey,
      floatingActionButton: new FloatingActionButton(
        onPressed: () {
          updateOrder(inCart: true);
          final int n = currentOrder.quantity;
          showSnackBarMessage(
            'There ${ n == 1 ? "is one item" : "are $n items" } in the shopping cart.'
          );
        },
        backgroundColor: const Color(0xFF16F0F0),
        child: new Icon(
          icon: Icons.add_shopping_cart,
          color: Colors.black
        )
      ),
      body: new Block(
        children: <Widget>[
          new OrderItem(
            product: config.order.product,
            quantity: currentOrder.quantity,
            quantityChanged: (int value) { updateOrder(quantity: value); }
          ),
          new SizedBox(height: 24.0),
          new FixedColumnCountGrid(
            columnCount: 2,
            rowSpacing: 8.0,
            columnSpacing: 8.0,
            padding: const EdgeInsets.all(8.0),
            tileAspectRatio: 160.0 / 216.0, // width/height
            children: config.products
              .where((Product product) => product != config.order.product)
              .map((Product product) {
              return new Card(
                elevation: 0,
                child: new NetworkImage(
                  fit: ImageFit.contain,
                  src: product.imageUrl
                )
              );
            }).toList()
          )
        ]
      )
    );

  }
}

/// Displays a full-screen modal OrderPage.
///
/// The order field will be replaced each time the user reconfigures the order.
/// When the user backs out of this route the completer's value will be the
/// final value of the order field.
class ShrineOrderRoute extends ShrinePageRoute<Order> {
  ShrineOrderRoute({
    this.order,
    WidgetBuilder builder,
    Completer<Order> completer,
    RouteSettings settings: const RouteSettings()
  }) : super(builder: builder, completer: completer, settings: settings) {
    assert(order != null);
  }

  Order order;

  @override
  Order get currentResult => order;

  static ShrineOrderRoute of(BuildContext context) => ModalRoute.of(context);
}
