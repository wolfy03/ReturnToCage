# 저장 형식 v5

기본 경로는 `user://return_to_cage_save.json`이다. Save v5는 transient ENet 연결 상태와 persistent domain state를 분리한다.

```text
format_version: 5
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

Offline은 동일한 v5 schema에 local profile player 하나를 저장한다. Multiplayer client는 파일을 쓸 수 없다. Host는 모든 active player가 Settlement safe boundary에 있을 때 canonical registry의 attached 및 detached PlayerState를 모두 저장할 수 있다. 어느 한 player라도 Adventure world에 참여 중이면 runtime world state와 unsecured loot가 Save v5에 포함되지 않으므로 Save를 거부한다. Load는 offline 또는 remote peer가 아직 없는 host에서만 허용하며, ADVENTURE/RESPAWNING 중에는 거부한다.

`Host Save`는 offline `Load Game` 뒤에 fresh Host를 실행하지 않는다. 아래 후보 선정 정책으로 고른 Save(primary 우선, 무효일 때만 검증된 backup)를 read/migrate/full-stage한 뒤에만 ENet transport를 `HOSTING_RESTORING` 상태로 열며, 이 상태에서는 protocol handshake가 canonical state를 변경할 수 없다. Transport bind가 성공한 뒤 staged snapshot을 적용하여 모든 `players[player_id]`를 복원하고 local profile player만 peer `1`에 attach한다. Network roster와 host world-ready invariant가 확인된 후에만 handshake gate를 열고 `hosting_started`를 emit한다. Saved remote records는 peer ID 없이 detached 상태로 남는다. Staging 실패는 transport를 열지 않고, bind 실패는 live session을 변경하지 않으며, post-open 실패는 transport를 닫고 offline local identity로 복귀한다.

Loader는 독립 `SessionSnapshot`에 shared와 모든 player record를 먼저 복원하고 전체 검증이 성공한 경우에만 live `GameSession`을 교체한다. Local profile의 player record가 없거나 player ID가 형식에 맞지 않으면 load를 거부한다. 복원된 remote player는 persistent registry에 detached 상태로 남고 local profile player만 peer 1에 attach한다.

## Item instance 검증

장비는 기존 숫자 키 사전을 사용한다. `0`은 무기, `1`은 몸통이며 5단계에서
`2` 머리, `3` 첫 장신구, `4` 두 번째 장신구를 추가했다. 슬롯이 없는 기존
Save v5 및 마이그레이션된 저장은 해당 칸을 빈 상태로 복원한다.

하나의 global instance registry가 settlement storage/pending loot, 모든 player inventory/protected inventory/equipment, death drops를 함께 검사한다. 비어 있지 않은 `instance_id`가 두 container나 두 player에 중복되면 Save v5 전체를 거부한다. Stack 수량, max stack, durability, equipment slot 검증은 기존 `StackValidation`을 재사용한다. Player item runtime revision과 settlement/quest replication revision은 load 후 다시 시작한다.

## Migration

Migration은 입력 envelope를 deep-copy한 뒤 순차 수행한다.

1. v1 → v2: difficulty overrides와 protected inventory 기본값 추가.
2. v2 → v3: active effects, death drops, pending loot 기본값 추가.
3. v3 → v4: flat shared fields를 `shared`로 이동하고 기존 단일 player를 현재 유효한 `LocalPlayerProfile.player_id` 아래에 배치.
4. v4 → v5: 일반·보호 인벤토리와 보관함을 `{capacity, slots:[{index, stack}]}`로 감싼다. 기존 순서·수량·instance ID를 유지하고 용량은 기본값과 기존 레코드 수 중 큰 값으로 추정한다.

v3에는 PERSONAL progression이 없으므로 migration은 빈 personal quest collection을 만든다. 임시 player ID를 발급해 migration하지 않는다. Local profile identity를 확보하지 못하면 migration을 실패시킨다. 기존 v1/v2 fixture는 수정하지 않고 v5까지 실제 load하는 회귀 테스트에 사용한다. 미래 버전과 malformed version은 거부한다.

## Profile과 Save 분리

`user://local_player_profile.json`은 “이 설치의 player identity가 무엇인가”를 저장한다. `user://local_player_profile.json.bak`은 이전 세대 history가 아니라 같은 identity의 검증 가능한 redundant copy다. 쓰기는 `.tmp`를 flush하고 다시 검증한 후 backup과 primary를 안전하게 교체한다. 두 파일의 호출 전 raw bytes/존재 상태는 별도 transaction rollback copy로 보존되며, 어느 설치 또는 최종 검증 단계가 실패해도 둘 다 호출 전 상태로 되돌린다. 두 disk copy의 commit이 모두 성공한 뒤에만 선택한 identity를 memory에서 활성화한다. 유효한 primary는 missing/stale backup을 보강하고, primary가 손상됐지만 backup이 유효하면 같은 ID로 primary를 복구한다. 두 파일이 모두 처음부터 없을 때만 새 ID를 만들며, 파일이 있었지만 둘 다 invalid이면 `IDENTITY_RECOVERY_REQUIRED` 상태를 유지한다.

개발/테스트용 `--local-profile-path=X` override는 primary `X`, backup `X.bak`, temporary `X.tmp`를 사용한다. Profile version과 game save version은 서로 독립이다.

## Primary/Backup 후보 선정과 저장 트랜잭션

`SaveManager.resolve_save_candidate(path)`가 Load, `prepare_load()`, Host Saved Game, identity inspection/validation/recovery의 유일한 파일 선택 경로다. 후보는 primary `path`와 backup `path.bak` 둘뿐이며 `.tmp`, `.bak.rollback`, `.corrupt`는 어떤 경우에도 후보가 아니다. 각 후보는 존재 → 읽기 → JSON parse → Dictionary → `format_version`(1–5 정수) → v1–v5 migration → `GameSession.prepare_persistent_restore()` full staging 순서로 검증한다. Full staging은 save 안의 **모든** player record를 복원하므로(첫 번째 player ID로 probe) 결과가 요청 identity와 무관하다. 즉 primary가 이 검증을 통과하면 local profile player가 없거나 다른 사람의 identity만 있어도 primary가 선택되고, 그 identity 오류는 그대로 보고된다. backup으로 다른 identity를 자동 선택하지 않는다. Primary가 없거나 검증에 실패할 때만 backup을 같은 파이프라인으로 검증하며, 그것도 실패하면 load는 실패하고 live `GameSession`은 변경되지 않는다.

Backup으로 load에 성공하면 결과(`last_load_result`, `prepare_load()`의 `source`/`recovered_from_backup`/`primary_error`/`notice`)와 메시지에 `Primary save is missing or corrupted. A valid backup was found.`가 포함되고, 같은 문장이 `GameSession.last_message`로 HUD status에 표시된다. Load와 Host Saved Game은 복구 후 파일을 쓰지 않는다. 복구된 세션은 다음 정상 Save 때 기존 정책대로 primary로 기록된다.

Writer(`save_game`)는 다음 불변식을 지킨다.

1. 새 데이터는 `.tmp`에 write/flush/close한 뒤 다시 읽어 byte 일치와 위 full validation을 통과해야 한다. 이 단계까지는 기존 primary/backup을 전혀 건드리지 않는다.
2. 기존 primary가 **유효**하면: 기존 `.bak`을 삭제하지 않고 `.bak.rollback`으로 옮기고, primary를 `.bak`으로, `.tmp`를 primary로 rename한다. 성공 후에만 `.bak.rollback`을 지운다(실패 시 다음 저장에서 정리).
3. 기존 primary가 **무효**하면: 그것을 `.bak`으로 회전하지 않는다(유일한 정상 사본일 수 있는 backup을 덮지 않기 위해). 무효 primary는 `.corrupt`로 보존하고(이전 `.corrupt`는 교체) `.bak`은 그대로 둔 채 `.tmp`를 primary로 설치한다.
4. Primary가 없으면 `.bak`을 그대로 두고 `.tmp`만 설치한다.
5. 어느 rename이 실패해도 옮겼던 파일을 원래 자리로 되돌린다. 되돌리기 자체가 실패해도 이전 정상 primary는 `.bak`에 남아 있으므로 다음 Load가 backup으로 복구한다.

모든 단계는 rename 대상이 비어 있는 상태에서만 rename하므로 Windows와 POSIX에서 같은 의미다.

**디스크 내구성의 한계.** `FileAccess.flush()`는 Godot/C 버퍼를 운영체제로 넘길 뿐 `fsync`가 아니며, rename 이후 디렉터리 entry도 fsync하지 않는다. 따라서 위 보장은 프로세스 crash, 강제 종료, 개별 파일 작업 실패에 대한 것이다. 정전이나 OS crash 시에는 OS가 아직 디스크에 쓰지 않은 내용이 사라지거나 rename 순서가 재배열될 수 있어 primary/backup이 모두 비거나 잘린 상태가 될 수 있다. 이 경우 loader는 손상을 검출해 실패를 보고할 뿐 데이터를 복원하지 못한다. Godot 4.7 API에는 파일·디렉터리 fsync가 없어 이 단계에서는 문서화된 잔여 위험으로 남긴다.

Identity recovery backend는 Load와 같은 후보 선정 정책으로 고른 Save가 v4 또는 v5일 때 `players` key를 persistent identity candidate로 읽는다. Inspection은 후보 Save를 detached `SessionSnapshot`으로 full staging해 검증하고 candidate를 문자열 사전순으로 반환하지만 Save, profile, live `GameSession`을 변경하지 않는다. 결과에는 출처(`source`: primary/backup)와 파일 내용 fingerprint가 포함되며, AppRoot는 이 값을 `recover_identity_from_save(..., expected)`에 그대로 넘긴다. 그 사이 Save가 바뀌었거나 다른 파일이 선택되면 복구를 거절하고 dialog를 다시 inspection으로 채운다. 빈 `players`는 candidate 0개인 정상 Save가 아니라 invalid Save v5다. Legacy v1–v3은 identity source로 사용하지 않는다. 선택된 ID를 실제로 복구할 때는 같은 후보를 다시 확인하고 모든 shared/player state, global item instance registry, death drop, quest를 기존 `SessionSnapshot`에 full staging한 뒤에만 `NetworkManager`의 identity commit 경계를 호출한다.

`LocalPlayerProfile`은 profile file validation과 transactional persistence를 담당하고 mutable object로 일반 production caller에 노출되지 않는다. `NetworkManager`가 active local logical identity와 commit precondition을 소유하며, `SaveManager`는 Save inspection/staging과 commit 요청만 orchestration한다. Profile recovery 성공은 live Save snapshot을 암묵적으로 적용하지 않으며, startup gate가 별도 offline identity activation을 완료한 뒤 menu action을 연다.

Startup에서는 `AppRoot`가 profile load status를 검사한다. 정상 primary, 신규 생성, backup 복구는 즉시 ready다. `IDENTITY_RECOVERY_REQUIRED`만 modal selection UI를 열며 single candidate도 사용자 확인이 필요하고 multiple candidate는 full player ID를 selection key로 명시 선택한다. 표시는 ID 마지막 12자리 fingerprint와 optional root `saved_at`만 사용한다. Cancel은 파일과 session을 변경하지 않고 모든 session action을 계속 잠그며, Create New Player는 별도 경고 확인 뒤 동일 transactional profile writer로 새 ID를 만든다.

Candidate recovery 또는 새 ID commit이 성공하면 Save snapshot을 apply하지 않는다. 대신 `GameSession.activate_offline_local_identity()`가 fresh menu-domain local state를 하나만 만들고 profile ID와 일치하는지 확인한다. 그 검증 후에만 New Game, Load, Host Save, Host, Join이 활성화된다. Profile commit 이후 activation만 실패한 경우 dialog는 candidate recovery와 분리된 activation-only mode/signal을 사용한다. 따라서 candidate 선택이 없는 Create New 경로에서도 profile이나 Save를 다시 검증·기록하지 않고 activation만 반복 재시도한다. Profile v1은 그대로 유지되며, Protocol v12에서 도입된 owner-private/network-world DTO는 Save의 player-state Dictionary를 그대로 전송하지 않는다. Protocol v13이 추가한 stamina 복제도 transient runtime state이며 Save에 포함되지 않는다.

`PlayerWorldState`는 active runtime participation이며 Save v5에 기록하지 않는다. Save와 Saved Host는 Settlement safe boundary에서 모든 canonical player의 world state를 `settlement`로 다시 초기화한다. Persistent identity/state는 `player_id`와 Save v5가 담당하고, 현재 scene/world revision/readiness는 transport lifetime에만 존재한다.

`last_safe_position`은 서버 또는 offline authority가 승인한 마지막 Settlement-domain 위치다. 매 프레임 transform이나 Adventure 좌표를 기록하지 않는다. Reconnect 때 이 값은 후보일 뿐이며 live Settlement spawn policy가 bounds, collision clearance, walkable support를 다시 검증한다. World-invalid 값은 configured fallback으로 대체되어 self-heal된다. Fresh spawn slot 배정은 runtime-only라 Save v5 schema에 추가되지 않는다.

Process-restart E2E는 primary profile과 `.bak`, primary Save v5를 역할별 독립 `user://`에서 실제 재사용한다. 새 Host process는 저장된 `session_id`, `play_time_seconds`, host state와 detached remote records를 복원하고, 새 client process는 같은 persistent `player_id`로 기존 canonical record에 attach된다. 후속 Save에서 fallback으로 치유된 safe position이 기록되는 것도 검증한다. 이 흐름에서도 Save에는 active peer mapping, world-ready, spawn slot/assignment, replication cache가 추가되지 않는다.

슬롯 인덱스·용량의 검증, 이전 배열과의 차이, 원본 파일 보존 정책은 [슬롯 저장 및 복제](inventory_persistence.md)를 참고한다.
