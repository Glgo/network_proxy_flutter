import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:date_format/date_format.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:network_proxy/network/host_port.dart';
import 'package:network_proxy/network/http/http.dart';
import 'package:network_proxy/network/http_client.dart';
import 'package:network_proxy/storage/favorites.dart';
import 'package:network_proxy/ui/component/utils.dart';
import 'package:network_proxy/ui/component/widgets.dart';
import 'package:network_proxy/ui/content/panel.dart';
import 'package:network_proxy/utils/curl.dart';
import 'package:window_manager/window_manager.dart';

class Favorites extends StatefulWidget {
  final NetworkTabController panel;

  const Favorites({super.key, required this.panel});

  @override
  State<StatefulWidget> createState() {
    return _FavoritesState();
  }
}

class _FavoritesState extends State<Favorites> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: FavoriteStorage.favorites,
        builder: (BuildContext context, AsyncSnapshot<Queue<Favorite>> snapshot) {
          if (snapshot.hasData) {
            var favorites = snapshot.data ?? Queue();
            if (favorites.isEmpty) {
              return const Center(child: Text("暂无收藏"));
            }

            return ListView.separated(
              itemCount: favorites.length,
              itemBuilder: (_, index) {
                var request = favorites.elementAt(index);
                return _FavoriteItem(
                  request,
                  index: index,
                  panel: widget.panel,
                  onRemove: (Favorite favorite) {
                    FavoriteStorage.removeFavorite(favorite);
                    FlutterToastr.show('已删除收藏', context);
                    setState(() {});
                  },
                );
              },
              separatorBuilder: (_, __) => const Divider(height: 1, thickness: 0.3),
            );
          } else {
            return const SizedBox();
          }
        });
  }
}

class _FavoriteItem extends StatefulWidget {
  final int index;
  final Favorite favorite;
  final NetworkTabController panel;
  final Function(Favorite favorite)? onRemove;

  const _FavoriteItem(this.favorite, {required this.panel, required this.onRemove, required this.index});

  @override
  State<_FavoriteItem> createState() => _FavoriteItemState();
}

class _FavoriteItemState extends State<_FavoriteItem> {
  //选择的节点
  static _FavoriteItemState? selectedState;

  bool selected = false;
  late HttpRequest request;

  @override
  void initState() {
    super.initState();
    request = widget.favorite.request;
  }

  @override
  Widget build(BuildContext context) {
    var response = widget.favorite.response;
    var title = '${request.method.name} ${request.requestUrl}';
    var time = formatDate(request.requestTime, [mm, '-', d, ' ', HH, ':', nn, ':', ss]);
    return GestureDetector(
        onSecondaryLongPressDown: menu,
        child: ListTile(
            minLeadingWidth: 25,
            leading: getIcon(response),
            title: Text(widget.favorite.name ?? title, overflow: TextOverflow.ellipsis, maxLines: 2),
            subtitle: Text.rich(
                style: const TextStyle(fontSize: 12),
                maxLines: 1,
                TextSpan(children: [
                  TextSpan(text: '#${widget.index} ', style: const TextStyle(color: Colors.teal)),
                  TextSpan(
                      text:
                          '$time - [${response?.status.code ?? ''}]  ${response?.contentType.name.toUpperCase() ?? ''} ${response?.costTime() ?? ''} '),
                ])),
            selected: selected,
            dense: true,
            onTap: onClick));
  }

  ///右键菜单
  menu(LongPressDownDetails details) {
    showContextMenu(
      context,
      details.globalPosition,
      items: <PopupMenuEntry>[
        popupItem("复制请求链接", onTap: () {
          var requestUrl = request.requestUrl;
          Clipboard.setData(ClipboardData(text: requestUrl)).then((value) => FlutterToastr.show('已复制到剪切板', context));
        }),
        popupItem("复制请求和响应", onTap: () {
          Clipboard.setData(ClipboardData(text: copyRequest(request, request.response)))
              .then((value) => FlutterToastr.show('已复制到剪切板', context));
        }),
        popupItem("复制 cURL 请求", onTap: () {
          Clipboard.setData(ClipboardData(text: curlRequest(request)))
              .then((value) => FlutterToastr.show('已复制到剪切板', context));
        }),
        const PopupMenuDivider(height: 0.3),
        popupItem("重命名", onTap: () => rename(widget.favorite)),
        popupItem("重放请求", onTap: () {
          var httpRequest = request.copy(uri: request.requestUrl);
          var proxyInfo = widget.panel.proxyServer.isRunning ? ProxyInfo.of("127.0.0.1", widget.panel.proxyServer.port) : null;
          HttpClients.proxyRequest(httpRequest, proxyInfo: proxyInfo);

          FlutterToastr.show('已重新发送请求', context);
        }),
        popupItem("编辑请求重放", onTap: () {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            requestEdit();
          });
        }),
        const PopupMenuDivider(height: 0.3),
        popupItem("删除收藏", onTap: () {
          widget.onRemove?.call(widget.favorite);
        })
      ],
    );
  }

  PopupMenuItem popupItem(String text, {VoidCallback? onTap}) {
    return CustomPopupMenuItem(height: 35, onTap: onTap, child: Text(text, style: const TextStyle(fontSize: 13)));
  }

  //重命名
  rename(Favorite item) {
    String? name = item.name;
    showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            content: TextFormField(
              initialValue: name,
              decoration: const InputDecoration(label: Text("名称")),
              onChanged: (val) => name = val,
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
              TextButton(
                child: const Text('保存'),
                onPressed: () {
                  Navigator.maybePop(context);
                  setState(() {
                    item.name = name?.isEmpty == true ? null : name;
                    FavoriteStorage.flushConfig();
                  });
                },
              ),
            ],
          );
        });
  }

  ///请求编辑
  requestEdit() async {
    var size = MediaQuery.of(context).size;
    var ratio = 1.0;
    if (Platform.isWindows) {
      ratio = WindowManager.instance.getDevicePixelRatio();
    }

    final window = await DesktopMultiWindow.createWindow(jsonEncode(
      {'name': 'RequestEditor', 'request': request},
    ));
    window.setTitle('请求编辑');
    window
      ..setFrame(const Offset(100, 100) & Size(960 * ratio, size.height * ratio))
      ..center()
      ..show();
  }

  //点击事件
  void onClick() {
    if (selected) {
      return;
    }
    setState(() {
      selected = true;
    });

    //切换选中的节点
    if (selectedState?.mounted == true && selectedState != this) {
      selectedState?.setState(() {
        selectedState?.selected = false;
      });
    }
    selectedState = this;
    widget.panel.change(request, request.response);
  }
}
