# HIFS 차량 등록

GitHub Pages(화면) + Supabase(DB·관리자 로그인)로 동작하는 차량 등록/조회 웹페이지입니다.

```
hifs-vehicle/
├─ index.html            ← 웹페이지 전체 (화면 + 동작)
├─ supabase/schema.sql   ← DB 테이블·보안 정책·등록 함수·관리자 권한
└─ README.md
```

`index.html`의 Supabase 설정이 비어 있으면 **미리보기 모드**(이 브라우저에만 저장)로 동작합니다.
미리보기 관리자 계정 (비밀번호 `hifs1234!`): `admin@hifs.example`(최고 관리자), `staff@hifs.example`(일반 관리자)

---

## 1. Supabase 설정 (DB)

1. https://supabase.com 가입 → **New project** (Region: Northeast Asia (Seoul) 권장)
2. 왼쪽 **SQL Editor → New query**에 `supabase/schema.sql` 전체를 붙여넣고 **Run**
3. **Authentication → Sign In / Providers → Email**
   - **Allow new users to sign up** 를 **끄기** ← 가장 중요 (외부인이 계정을 만들지 못하게)
4. **Authentication → Users → Add user → Create new user**
   - 교직원마다 개인 이메일/비밀번호로 계정 생성 (Auto Confirm 체크)
5. **첫 최고 관리자 지정 (처음 한 번만)** — SQL Editor에서 이메일·이름만 바꿔 실행:
   ```sql
   insert into public.admins (user_id, display_name, role)
   select id, '홍길동', 'super' from auth.users where email = 'teacher1@hifs.kr'
   on conflict (user_id) do update set role = 'super';
   ```
   이후 다른 교직원은 홈페이지 **관리자 → 관리자 관리** 탭에서 이메일로 추가합니다.
   (계정 자체는 4번처럼 Supabase에서 먼저 만들어야 합니다)

   | 권한 | 할 수 있는 일 |
   |---|---|
   | 최고 관리자 | 조회·등록·메모 + **삭제, CSV 업로드, 관리자 추가/권한 변경/빼기** |
   | 일반 관리자 | 조회·등록·메모 |

   최고 관리자는 항상 최소 1명 남도록 막혀 있습니다.
6. **Project Settings → API**(또는 API Keys)에서 두 값을 복사
   - Project URL (예: `https://abcdefgh.supabase.co`)
   - `anon` `public` 키 또는 `publishable` 키
   - ⚠ `service_role` / `secret` 키는 **절대** index.html에 넣지 마세요.

## 2. index.html 에 연결 정보 넣기

`index.html` 안 `CONFIG` 부분:

```js
SUPABASE_URL: 'https://abcdefgh.supabase.co',
SUPABASE_ANON_KEY: '복사한 anon(publishable) 키',
```

anon 키는 공개돼도 괜찮은 키입니다. 실제 데이터는 DB의 보안 정책(RLS)이 막습니다.

## 3. GitHub Pages 로 배포

1. GitHub에서 **New repository** 생성 (예: `hifs-vehicle`)
2. **Add file → Upload files**로 `index.html`(와 나머지 파일) 업로드 → Commit
3. **Settings → Pages → Build and deployment**
   - Source: **Deploy from a branch** / Branch: **main**, 폴더 **/(root)** → Save
4. 1~2분 뒤 `https://<GitHub아이디>.github.io/hifs-vehicle/` 로 접속
5. Supabase **Authentication → URL Configuration → Site URL**에 위 주소 입력

> 무료 GitHub 계정은 Pages를 쓰려면 저장소가 **Public**이어야 합니다. 코드가 공개돼도
> anon 키뿐이고 데이터는 RLS로 보호되므로 괜찮습니다. (service_role 키만 올리지 않으면 됩니다)

## 4. 링크 2개

| 용도 | 링크 | 보이는 화면 |
|---|---|---|
| 학부모용 (공지·문자로 배포) | `https://<GitHub아이디>.github.io/<저장소이름>/` | 차량 등록만 |
| 관리자용 (교직원끼리만 공유) | `https://<GitHub아이디>.github.io/<저장소이름>/#admin` | 관리자 로그인 → 로그인 후 조회·관리 |

- 관리자 링크 끝부분은 `index.html`의 `CONFIG.ADMIN_HASH`로 바꿀 수 있습니다 (예: `'hifs-staff'` → `…/#hifs-staff`).
- 관리자 링크는 휴대폰 홈 화면에 추가해 두면 앱처럼 쓸 수 있습니다.
- 링크가 알려져도 관리자 계정과 비밀번호가 없으면 아무것도 볼 수 없습니다.

## 5. 나중에 바꿀 것들

| 바꿀 내용 | 위치 |
|---|---|
| 상단 제목 | `index.html`의 `<title>`과 `<h1>` |
| English 반 목록 | Supabase **Table Editor → class_options** (행 추가/수정, `is_active` 끄기) |
| 다른 소속도 드롭다운으로 | `class_options`에 해당 소속 행 추가 |
| 관리자 버튼 숨기기 | `CONFIG.HIDE_ADMIN_ENTRY` (현재 `true` = 숨김) |
| 관리자 링크 끝부분 | `CONFIG.ADMIN_HASH` |
| 자동 로그아웃 시간 | `CONFIG.IDLE_LOGOUT_MINUTES` |

## 보안 구조 요약

- 방문자(로그인 안 함): `register_family` 함수로 **등록만** 가능, 어떤 데이터도 읽을 수 없음
- 관리자: `admins` 테이블에 있는 계정으로 로그인했을 때만 조회·수정 가능, 삭제·CSV·관리자 관리는 최고 관리자만 (모두 DB에서 검사)
- 회원가입 차단, 비밀번호 5회 실패 시 10분 잠금(화면) + Supabase 자체 시도 횟수 제한
- 브라우저를 닫거나 2시간 동안 사용하지 않으면 로그아웃
- 조회 기록은 `audit_logs` 테이블에 누가·언제·무엇을 검색했는지 남음
