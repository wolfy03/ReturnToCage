# 저장 형식 v4

기본 경로는 `user://return_to_cage_save.json`이다. Save v4는 transient ENet 연결 상태와 persistent domain state를 분리한다.

```text
format_version: 4
saved_at
shared
  session
  settlement
  progression
  difficulty
  adventure
players
  <persistent player_id>
    player_state
    personal_progression
```

`shared.progression`에는 PARTY/WORLD 퀘스트와 공용 unlock이 들어간다. `players[player_id].personal_progression`에는 그 플레이어의 PERSONAL 퀘스트가 들어간다. `player_state`는 stats, health, survival, effects, last-safe position, inventory, protected inventory, equipment를 기존 typed model의 저장 API로 직렬화한다. `peer_id`, world-ready 상태, command sequence, actor/runtime ID, replication revision/cache는 저장하지 않는다.

`shared.settlement`에는 storage, pending loot, facility level, resident domain state를 저장한다. `shared.adventure`는 활성 원정을 재개하지 않고 persistent death-drop record만 보존한다. Death drop 소유권은 선택적 stable `owner_player_id`로 저장하며 transient `owner_peer_id`는 저장하지 않는다. 기존 owner 없는 v1–v3 record는 shared recovery 호환성을 유지한다. 원정 중 프로세스 종료 복귀는 아직 지원하지 않는다.

## 저장 및 로드 권위

Offline은 동일한 v4 schema에 local profile player 하나를 저장한다. Multiplayer client는 파일을 쓸 수 없다. Host는 모든 active player가 Settlement safe boundary에 있을 때 canonical registry의 attached 및 detached PlayerState를 모두 저장할 수 있다. 어느 한 player라도 Adventure world에 참여 중이면 runtime world state와 unsecured loot가 Save v4에 포함되지 않으므로 Save를 거부한다. Load는 offline 또는 remote peer가 아직 없는 host에서만 허용하며, ADVENTURE/RESPAWNING 중에는 거부한다.

`Host Save`는 offline `Load Game` 뒤에 fresh Host를 실행하지 않는다. Primary Save를 read/migrate/full-stage한 뒤에만 ENet transport를 `HOSTING_RESTORING` 상태로 열며, 이 상태에서는 protocol handshake가 canonical state를 변경할 수 없다. Transport bind가 성공한 뒤 staged snapshot을 적용하여 모든 `players[player_id]`를 복원하고 local profile player만 peer `1`에 attach한다. Network roster와 host world-ready invariant가 확인된 후에만 handshake gate를 열고 `hosting_started`를 emit한다. Saved remote records는 peer ID 없이 detached 상태로 남는다. Staging 실패는 transport를 열지 않고, bind 실패는 live session을 변경하지 않으며, post-open 실패는 transport를 닫고 offline local identity로 복귀한다.

Writer는 `.tmp` write/flush/close, 기존 파일 `.bak` 이동, 최종 rename 전략을 유지한다. Temporary write, backup remove/rename, final rename 오류는 모두 실패로 보고하며 final rename 실패 시 backup rollback 결과도 확인한다. Loader는 독립 `SessionSnapshot`에 shared와 모든 player record를 먼저 복원하고 전체 검증이 성공한 경우에만 live `GameSession`을 교체한다. Local profile의 player record가 없거나 player ID가 형식에 맞지 않으면 load를 거부한다. 복원된 remote player는 persistent registry에 detached 상태로 남고 local profile player만 peer 1에 attach한다.

## Item instance 검증

하나의 global instance registry가 settlement storage/pending loot, 모든 player inventory/protected inventory/equipment, death drops를 함께 검사한다. 비어 있지 않은 `instance_id`가 두 container나 두 player에 중복되면 Save v4 전체를 거부한다. Stack 수량, max stack, durability, equipment slot 검증은 기존 `StackValidation`을 재사용한다. Player item runtime revision과 settlement/quest replication revision은 load 후 다시 시작한다.

## Migration

Migration은 입력 envelope를 deep-copy한 뒤 순차 수행한다.

1. v1 → v2: difficulty overrides와 protected inventory 기본값 추가.
2. v2 → v3: active effects, death drops, pending loot 기본값 추가.
3. v3 → v4: flat shared fields를 `shared`로 이동하고 기존 단일 player를 현재 유효한 `LocalPlayerProfile.player_id` 아래에 배치.

v3에는 PERSONAL progression이 없으므로 migration은 빈 personal quest collection을 만든다. 임시 player ID를 발급해 migration하지 않는다. Local profile identity를 확보하지 못하면 migration을 실패시킨다. 기존 v1/v2 fixture는 수정하지 않고 v4까지 실제 load하는 회귀 테스트에 사용한다. 미래 버전과 malformed version은 거부한다.

## Profile과 Save 분리

`user://local_player_profile.json`은 “이 설치의 player identity가 무엇인가”를 저장한다. `user://local_player_profile.json.bak`은 이전 세대 history가 아니라 같은 identity의 검증 가능한 redundant copy다. 쓰기는 `.tmp`를 flush하고 다시 검증한 후 backup과 primary를 안전하게 교체한다. 두 파일의 호출 전 raw bytes/존재 상태는 별도 transaction rollback copy로 보존되며, 어느 설치 또는 최종 검증 단계가 실패해도 둘 다 호출 전 상태로 되돌린다. 두 disk copy의 commit이 모두 성공한 뒤에만 선택한 identity를 memory에서 활성화한다. 유효한 primary는 missing/stale backup을 보강하고, primary가 손상됐지만 backup이 유효하면 같은 ID로 primary를 복구한다. 두 파일이 모두 처음부터 없을 때만 새 ID를 만들며, 파일이 있었지만 둘 다 invalid이면 `IDENTITY_RECOVERY_REQUIRED` 상태를 유지한다.

개발/테스트용 `--local-profile-path=X` override는 primary `X`, backup `X.bak`, temporary `X.tmp`를 사용한다. Profile version과 game save version은 서로 독립이다.

Identity recovery backend는 primary `return_to_cage_save.json`이 정확한 Save v4일 때만 `players` key를 persistent identity candidate로 읽는다. Inspection은 root/shared/player-record의 최소 contract를 검증하고 candidate를 문자열 사전순으로 반환하지만 domain object를 만들거나 Save, profile, live `GameSession`을 변경하지 않는다. 빈 `players`는 candidate 0개인 정상 Save가 아니라 invalid Save v4다. Legacy v1–v3 및 Save `.bak`은 identity source로 사용하지 않는다. 선택된 ID를 실제로 복구할 때는 primary Save를 다시 읽고 모든 shared/player state, global item instance registry, death drop, quest를 기존 `SessionSnapshot`에 full staging한 뒤에만 `NetworkManager`의 identity commit 경계를 호출한다.

`LocalPlayerProfile`은 profile file validation과 transactional persistence를 담당하고 mutable object로 일반 production caller에 노출되지 않는다. `NetworkManager`가 active local logical identity와 commit precondition을 소유하며, `SaveManager`는 Save inspection/staging과 commit 요청만 orchestration한다. Profile recovery 성공은 live Save snapshot을 암묵적으로 적용하지 않으며, startup gate가 별도 offline identity activation을 완료한 뒤 menu action을 연다.

Startup에서는 `AppRoot`가 profile load status를 검사한다. 정상 primary, 신규 생성, backup 복구는 즉시 ready다. `IDENTITY_RECOVERY_REQUIRED`만 modal selection UI를 열며 single candidate도 사용자 확인이 필요하고 multiple candidate는 full player ID를 selection key로 명시 선택한다. 표시는 ID 마지막 12자리 fingerprint와 optional root `saved_at`만 사용한다. Cancel은 파일과 session을 변경하지 않고 모든 session action을 계속 잠그며, Create New Player는 별도 경고 확인 뒤 동일 transactional profile writer로 새 ID를 만든다.

Candidate recovery 또는 새 ID commit이 성공하면 Save snapshot을 apply하지 않는다. 대신 `GameSession.activate_offline_local_identity()`가 fresh menu-domain local state를 하나만 만들고 profile ID와 일치하는지 확인한다. 그 검증 후에만 New Game, Load, Host Save, Host, Join이 활성화된다. Profile commit 이후 activation만 실패한 경우 dialog는 candidate recovery와 분리된 activation-only mode/signal을 사용한다. 따라서 candidate 선택이 없는 Create New 경로에서도 profile이나 Save를 다시 검증·기록하지 않고 activation만 반복 재시도한다. Save v4 schema는 그대로 유지되며, Protocol v11의 owner-private/network-world DTO는 Save의 player-state Dictionary를 그대로 전송하지 않는다.

`PlayerWorldState`는 active runtime participation이며 Save v4에 기록하지 않는다. Save와 Saved Host는 Settlement safe boundary에서 모든 canonical player의 world state를 `settlement`로 다시 초기화한다. Persistent identity/state는 `player_id`와 Save v4가 담당하고, 현재 scene/world revision/readiness는 transport lifetime에만 존재한다.

`last_safe_position`은 서버 또는 offline authority가 승인한 마지막 Settlement-domain 위치다. 매 프레임 transform이나 Adventure 좌표를 기록하지 않는다. Reconnect 때 이 값은 후보일 뿐이며 live Settlement spawn policy가 bounds, collision clearance, walkable support를 다시 검증한다. World-invalid 값은 configured fallback으로 대체되어 self-heal된다. Fresh spawn slot 배정은 runtime-only라 Save v4 schema에 추가되지 않는다.

Process-restart E2E는 primary profile과 `.bak`, primary Save v4를 역할별 독립 `user://`에서 실제 재사용한다. 새 Host process는 저장된 `session_id`, `play_time_seconds`, host state와 detached remote records를 복원하고, 새 client process는 같은 persistent `player_id`로 기존 canonical record에 attach된다. 후속 Save에서 fallback으로 치유된 safe position이 기록되는 것도 검증한다. 이 흐름에서도 Save에는 active peer mapping, world-ready, spawn slot/assignment, replication cache가 추가되지 않는다.
