// Copyright © 2023 Ory Corp
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:built_collection/built_collection.dart';
import 'package:built_value/json_object.dart';
import 'package:crypto/crypto.dart';
import 'package:deep_collection/deep_collection.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth/flutter_web_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:one_of/one_of.dart';
import 'package:ory_client/ory_client.dart';
import 'package:collection/collection.dart';
import 'package:ory_network_flutter/services/exceptions.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../services/auth.dart';

enum AuthStatus {
  uninitialized,
  authenticated,
  unauthenticated,
  aal2Requested,
  locationChangeRequired
}

class AuthRepository {
  final AuthService service;
  final GoogleSignIn googleSignIn;

  AuthRepository({required this.googleSignIn, required this.service});

  Future<Session> getCurrentSessionInformation() async {
    final session = await service.getCurrentSessionInformation();
    return session;
  }

  Future<LoginFlow> createLoginFlow({required String aal}) async {
    final flow = await service.createLoginFlow(aal: aal);
    return flow;
  }

  Future<RegistrationFlow> createRegistrationFlow() async {
    final flow = await service.createRegistrationFlow();
    return flow;
  }

  Future<LoginFlow> getLoginFlow({required String flowId}) async {
    final flow = await service.getLoginFlow(flowId: flowId);
    return flow;
  }

  Future<RegistrationFlow> getRegistrationFlow({required String flowId}) async {
    final flow = await service.getRegistrationFlow(flowId: flowId);
    return flow;
  }

  Future<void> logout() async {
    await service.logout();
  }

  Future<String> getWebAuthCode({required String url}) async {
    try {
      final result =
          await FlutterWebAuth.authenticate(url: url, callbackUrlScheme: 'ory');
      // get return to code
      final code = Uri.parse(result).queryParameters['code'];
      if (code != null) {
        return code;
      } else {
        throw const CustomException.unknown();
      }
    } on PlatformException catch (_) {
      throw const CustomException.unknown();
    }
  }

  Future<Session> exchangeCodesForSessionToken(
      {String? flowId, String? initCode, String? returnToCode}) async {
    if (flowId != null && initCode != null && returnToCode != null) {
      final session = service.exchangeCodesForSessionToken(
          flowId: flowId, initCode: initCode, returnToCode: returnToCode);
      return session;
    } else {
      throw const CustomException.unknown();
    }
  }

  Future<Session?> updateRegistrationFlow(
      {required String flowId,
      required UiNodeGroupEnum group,
      required String name,
      required String value,
      required List<UiNode> nodes}) async {
    // create request body
    var body = _createRequestBody(
        group: group, name: name, value: value, nodes: nodes);
    // user used social sign in
    if (group == UiNodeGroupEnum.oidc) {
      if (value.contains('google')) {
        final idToken = await _loginWithGoogle();
        // update body with id token and nonce
        _addIdTokenAndNonceToBody(idToken, body);
      }
      if (value.contains('apple')) {
        final idToken =
            Platform.isAndroid ? await null : await _logInWithAppleOnIOS();
        // update body with id token and nonce
        if (idToken != null) {
          _addIdTokenAndNonceToBody(idToken, body);
        }
      }
    }
    // submit registration and retrieve session
    final session = await service.updateRegistrationFlow(
        flowId: flowId, group: group, value: body);
    return session;
  }

  Future<Session> updateLoginFlow(
      {required String flowId,
      required UiNodeGroupEnum group,
      required String name,
      required String value,
      required List<UiNode> nodes}) async {
    // create request body
    var body = _createRequestBody(
        group: group, name: name, value: value, nodes: nodes);
    // user used social sign in
    if (group == UiNodeGroupEnum.oidc) {
      if (value.contains('google')) {
        final idToken = await _loginWithGoogle();
        // update body with id token and nonce
        _addIdTokenAndNonceToBody(idToken, body);
      }
      if (value.contains('apple')) {
        final idToken =
            Platform.isAndroid ? null : await _logInWithAppleOnIOS();
        // update body with id token and nonce
        if (idToken != null) {
          _addIdTokenAndNonceToBody(idToken, body);
        }
      }
    }
    // submit login
    final login = await service.updateLoginFlow(
        flowId: flowId, group: group, value: body);
    return login.session;
  }

  Map _getMapFromJWT(String splittedToken) {
    String normalizedSource = base64Url.normalize(splittedToken);
    return jsonDecode(utf8.decode(base64Url.decode(normalizedSource)));
  }

  _addIdTokenAndNonceToBody(String idToken, Map body) {
    // get nonce value from id token
    final jwtParts = idToken.split('.');
    final jwt = _getMapFromJWT(jwtParts[1]);
    // add id token and nonce to body
    body.addAll({'id_token': idToken, 'nonce': jwt['nonce']});
  }

  Future<String> _loginWithGoogle() async {
    try {
      final GoogleSignInAccount? account = await googleSignIn.signIn();

      final GoogleSignInAuthentication? googleAuth =
          await account?.authentication;
      if (googleAuth?.idToken != null) {
        return googleAuth!.idToken!;
      } else {
        throw const CustomException.unknown();
      }
    } catch (e) {
      throw const CustomException.unknown();
    }
  }

  Future<String> _logInWithAppleOnIOS() async {
    try {
      //Check if Apple SignIn is available for the device or not
      if (await SignInWithApple.isAvailable()) {
        // create nonce
        final rawNonce = generateNonce();
        final nonceInBytes = utf8.encode(rawNonce);
        final nonce = sha256.convert(nonceInBytes);
        // login
        final AuthorizationCredentialAppleID credential =
            await SignInWithApple.getAppleIDCredential(
          scopes: [AppleIDAuthorizationScopes.email],
          nonce: nonce.toString(),
        );

        if (credential.identityToken != null) {
          return credential.identityToken!;
        } else {
          throw const CustomException.unknown();
        }
      } else {
        throw const CustomException.unknown(
            message: 'Sign in with Apple is not available on your device');
      }
    } catch (e) {
      throw const CustomException.unknown();
    }
  }

  Map _createRequestBody(
      {required UiNodeGroupEnum group,
      required String name,
      required String value,
      required List<UiNode> nodes}) {
    // if name of submitted node is method, find all nodes that belong to the group
    if (name == 'method') {
      // get input nodes of the same group
      final inputNodes = nodes.where((p0) {
        if (p0.attributes.oneOf.isType(UiNodeInputAttributes)) {
          final attributes = p0.attributes.oneOf.value as UiNodeInputAttributes;
          // if group is password, find identifier
          if (group == UiNodeGroupEnum.password &&
              p0.group == UiNodeGroupEnum.default_ &&
              attributes.name == 'identifier') {
            return true;
          }
          return p0.group == group &&
              attributes.type != UiNodeInputAttributesTypeEnum.button &&
              attributes.type != UiNodeInputAttributesTypeEnum.submit;
        } else {
          return false;
        }
      });
      // create maps from attribute names and their values
      final nestedMaps = inputNodes.map((e) {
        final attributes = e.attributes.oneOf.value as UiNodeInputAttributes;

        return generateNestedMap(
            attributes.name, attributes.value?.asString ?? '');
      }).toList();

      // merge nested maps into one
      final mergedMap =
          nestedMaps.reduce((value, element) => value.deepMerge(element));

      return mergedMap;
    } else {
      return {name: value};
    }
  }

  RegistrationFlow changeRegistrationNodeValue(
      {required RegistrationFlow settings,
      required String name,
      required String value}) {
    // update node value
    final updatedNodes =
        updateNodes(nodes: settings.ui.nodes, name: name, value: value);
    // update settings' node
    final newFlow =
        settings.rebuild((p0) => p0..ui.nodes.replace(updatedNodes));
    return newFlow;
  }

  LoginFlow changeLoginNodeValue(
      {required LoginFlow settings,
      required String name,
      required String value}) {
    // update node value
    final updatedNodes =
        updateNodes(nodes: settings.ui.nodes, name: name, value: value);
    // update settings' node
    final newFlow =
        settings.rebuild((p0) => p0..ui.nodes.replace(updatedNodes));
    return newFlow;
  }

  BuiltList<UiNode> updateNodes(
      {required BuiltList<UiNode> nodes,
      required String name,
      required String value}) {
    // get edited node
    final node = nodes.firstWhereOrNull((element) {
      if (element.attributes.oneOf.isType(UiNodeInputAttributes)) {
        return (element.attributes.oneOf.value as UiNodeInputAttributes).name ==
            name;
      } else {
        return false;
      }
    });

    // udate value of edited node
    final updatedNode = node?.rebuild((p0) => p0
      ..attributes.update((b) {
        final oldValue = b.oneOf?.value as UiNodeInputAttributes;
        final newValue = oldValue.rebuild((p0) => p0.value = JsonObject(value));
        b.oneOf = OneOf1(value: newValue);
      }));
    // get index of to be updated node
    final nodeIndex = nodes.indexOf(node!);
    // update list of nodes to iclude updated node
    return nodes.rebuild((p0) => p0
      ..removeAt(nodeIndex)
      ..insert(nodeIndex, updatedNode!));
  }

  Map<dynamic, dynamic> generateNestedMap(String path, String value) {
    var steps = path.split('.');
    Object? result = value;
    for (var step in steps.reversed) {
      result = {step: result};
    }
    return result as Map<dynamic, dynamic>;
  }
}
