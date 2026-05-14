import 'package:flutter/material.dart';

import 'concert_after_screen.dart';
import 'concert_before_overlay.dart';
import 'widgets/diary_page_frame.dart';
import 'widgets/diary_tabs.dart';
import 'widgets/add_ticket_option.dart';
import 'widgets/pressable_scale.dart';
import 'widgets/tear_to_reveal_right.dart';
import 'widgets/ticket_flip_card.dart';


/// 앱의 다이어리 화면을 구성하기 위해 class생성.
class DiaryScreen extends StatefulWidget {
  const DiaryScreen({super.key});

  @override
  State<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends State<DiaryScreen> {
  bool _isAddTicketExpanded = false;

  /// 공연 전 티켓의 전역 위치/크기(Rect)를 얻기 위해 사용
  final GlobalKey _concertBeforeTicketKey = GlobalKey();

  /// 공연 후 티켓 우측의 '공연전' 바로가기 영역 Rect를 얻기 위해 사용
  final GlobalKey _concertBeforeShortcutKey = GlobalKey();

  Rect? _globalRectOf(GlobalKey key) {
	final ctx = key.currentContext;
	if (ctx == null) return null;
	final box = ctx.findRenderObject() as RenderBox?;
	if (box == null || !box.hasSize) return null;
	final topLeft = box.localToGlobal(Offset.zero);
	return topLeft & box.size;
  }

  /// 공연 후 티켓 우측의 '뜯는 조각(tear piece)' UI
  /// - 점선(절취선) 옆 조각으로, 슬라이드(드래그)하면 뜯기는 애니메이션이 시작됩니다.
  Widget _concertAfterTearPieceWidget() {
	return Container(
		color: Colors.white,
		child: Center(
			child: Text(
				'입장\n조각',
				textAlign: TextAlign.center,
				style: TextStyle(
					fontSize: 12,
					fontWeight: FontWeight.w700,
					color: Colors.black.withValues(alpha: 0.55),
				),
			),
		),
	);
  }

  @override
  Widget build(BuildContext context) {
	return DiaryPageFrame(
	  sideTabs: buildDiarySideTabs(context, active: DiaryTab.diary),
	  child: LayoutBuilder(
		builder: (context, constraints) {
		  final content = SingleChildScrollView(
			padding: const EdgeInsets.symmetric(horizontal: 25),
			child: ConstrainedBox(
			  constraints: BoxConstraints(minHeight: constraints.maxHeight),
			  child: Column(
				mainAxisAlignment: MainAxisAlignment.center,
				children: [
				  _buildAddTicketArea(context),
				  const SizedBox(height: 30),
					_buildTicketPocket(
					  child: TicketFlipCard(
						enabled: !_isAddTicketExpanded,
						// 원근/오버플로우를 줄여, 뒤집힐 때 다른 티켓 위로 크게 그려지는 느낌을 최소화
						perspective: 0.00055,
						clipBehavior: Clip.antiAlias,
						borderRadius: BorderRadius.circular(8),
						front: _buildTicketBeforeDelivery(),
						back: _buildTicketBeforeDeliveryBack(),
					  ),
					),
				  const SizedBox(height: 20),
						PressableScale(
							onTap: _isAddTicketExpanded
								? null
								: () {
									final startRect = _globalRectOf(_concertBeforeTicketKey);
									if (startRect == null) return;

									// 다이어리 화면 위에 그려지는(overlay) 공연 전 화면
									ConcertBeforeOverlay.show(
										context,
										startRect: startRect,
										collapsedTicket: _buildTicketPocket(
											child: _buildTicketBeforeConcert(),
										),
										concertTitle: '공연전',
									);
								},
						child: KeyedSubtree(
							key: _concertBeforeTicketKey,
							child: _buildTicketPocket(
								child: _buildTicketBeforeConcert(),
							),
						),
					),
				  const SizedBox(height: 20),
				  	PressableScale(
						onTap: _isAddTicketExpanded
							? null
							: () => Navigator.push(
								  context,
								  MaterialPageRoute(
									settings: const RouteSettings(name: DiaryRoutes.concertAfter),
									builder: (context) => const ConcertAfterScreen(concertTitle: "공연후"),
								  ),
								),
						child: _buildTicketPocket(
						  child: _buildTicketAfterConcert(context),
						),
				  	),
				],
			  ),
			),
		  );

		  /// 티켓 추가 옵션이 열려있을 때는 화면 아무 곳(추가 영역 밖)을 탭하면 닫히도록 처리
		  if (!_isAddTicketExpanded) return content;
		  return GestureDetector(
			behavior: HitTestBehavior.translucent,
			onTap: () => setState(() => _isAddTicketExpanded = false),
			child: content,
		  );
		},
	  ),
	);
  }

  /// 티켓 추가 영역(버튼 <-> 카메라/갤러리 선택 바)
  Widget _buildAddTicketArea(BuildContext context) {
	return AnimatedSwitcher(
	  duration: const Duration(milliseconds: 180),
	  switchInCurve: Curves.easeOut,
	  switchOutCurve: Curves.easeIn,
	  child: _isAddTicketExpanded
		  ? GestureDetector(
			  key: const ValueKey('add_ticket_options'),
			  behavior: HitTestBehavior.opaque,
			  onTap: () {},
			  child: _buildAddTicketOptions(context),
			)
		  : PressableScale(
			  key: const ValueKey('add_ticket_button'),
			  onTap: () => setState(() => _isAddTicketExpanded = true),
			  child: _buildAddTicketButton(),
			),
	);
  }

  Widget _buildAddTicketButton() {
	return Container(
	  height: 100,
	  decoration: BoxDecoration(
		color: Colors.white.withValues(alpha: 0.5),
		borderRadius: BorderRadius.circular(15),
		border: Border.all(color: Colors.grey.shade400, width: 2, style: BorderStyle.solid),
	  ),
	  child: const Center(
		child: Text(
		  "티켓  추가",
		  style: TextStyle(
			fontSize: 26,
			fontWeight: FontWeight.bold,
			color: Colors.black87,
			letterSpacing: 4.0,
		  ),
		),
	  ),
	);
  }

  /// 카메라/갤러리 선택 바
  /// - 티켓 추가 버튼과 동일한 높이(100)로 맞춰 "작아 보이는" 느낌 제거
  /// - 가운데 구분선은 점선 대신 얇은 실선으로 변경
  Widget _buildAddTicketOptions(BuildContext context) {
	return Container(
	  height: 100,
	  decoration: BoxDecoration(
		color: Colors.white.withValues(alpha: 0.60),
		borderRadius: BorderRadius.circular(15),
		border: Border.all(color: Colors.grey.shade400, width: 2),
		boxShadow: [
		  BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(2, 4)),
		],
	  ),
	  child: Row(
		children: [
		  Expanded(
			child: AddTicketOption(
			  icon: Icons.photo_camera_outlined,
			  label: '카메라',
			  onTap: () {
				setState(() => _isAddTicketExpanded = false);
				ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('카메라 선택')));
			  },
			),
		  ),
		  Container(
			width: 1,
			margin: const EdgeInsets.symmetric(vertical: 14),
			color: Colors.black.withValues(alpha: 0.18),
		  ),
		  Expanded(
			child: AddTicketOption(
			  icon: Icons.photo_library_outlined,
			  label: '갤러리',
			  onTap: () {
				setState(() => _isAddTicketExpanded = false);
				ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('갤러리 선택')));
			  },
			),
		  ),
		],
	  ),
	);
  }

  /// 티켓 포켓 생성 위젯
  Widget _buildTicketPocket({required Widget child}) {
	return Container(
	  height: 120,
	  decoration: BoxDecoration(
		color: Colors.white.withValues(alpha: 0.4),
		borderRadius: BorderRadius.circular(10),
		border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 2),
		boxShadow: [
		  BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 5, offset: const Offset(2, 2)),
		],
		gradient: LinearGradient(
		  begin: Alignment.topLeft,
		  end: Alignment.bottomRight,
		  colors: [
			Colors.white.withValues(alpha: 0.6),
			Colors.white.withValues(alpha: 0.0),
			Colors.white.withValues(alpha: 0.2),
		  ],
		),
	  ),
	  child: Padding(
		padding: const EdgeInsets.all(10.0),
		child: child,
	  ),
	);
  }

  /// 배송 전 티켓 UI
  Widget _buildTicketBeforeDelivery() {
	return Row(
	  children: [
		Expanded(
		  flex: 3,
		  child: Container(
			decoration: const BoxDecoration(
			  color: Colors.white,
			  borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
			),
			padding: const EdgeInsets.all(12),
			child: const Column(
			  crossAxisAlignment: CrossAxisAlignment.start,
			  mainAxisAlignment: MainAxisAlignment.center,
			  children: [
				Text("배송전", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
				Spacer(),
				Center(
				  child: Text(
					"배송 날짜\n(D-day)",
					textAlign: TextAlign.center,
					style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
				  ),
				),
				Spacer(),
			  ],
			),
		  ),
		),
		Container(width: 1, color: Colors.grey.shade400),
		Expanded(
		  flex: 1,
		  child: Container(
			decoration: const BoxDecoration(
			  color: Colors.white,
			  borderRadius: BorderRadius.horizontal(right: Radius.circular(8)),
			),
			child: const Center(
			  child: Text(
				"예매처\n아이콘",
				textAlign: TextAlign.center,
				style: TextStyle(fontSize: 12, color: Colors.black54),
			  ),
			),
		  ),
		),
	  ],
	);
  }

	/// 배송 전 티켓 - 뒷면(공연 정보)
	///
	/// 요구사항
	/// 1) 뒤집혔을 때 좌/우로 나뉜 티켓이 아니라 '하나의 티켓 영역'으로 보이기
	/// 2) 정보는 티켓 중앙을 기준으로 2열로 흐르기(좌: 날짜/시간/공연장, 우: 좌석/가격)
	///
	/// NOTE: 현재 프로젝트에는 티켓/공연 모델이 별도로 없어서, 우선 샘플 값으로 표시합니다.
	Widget _buildTicketBeforeDeliveryBack() {
		const date = '2024.06.15';
		const time = '17:00';
		const venue = '콘서트홀';
		const seat = 'A구역 12열 8번';
		const price = '₩110,000';

		Widget infoRow(
			String label,
			String value, {
			int maxLines = 1,
		}) {
			return Row(
				crossAxisAlignment: CrossAxisAlignment.start,
				children: [
					SizedBox(
						width: 36,
						child: Text(
							label,
							style: const TextStyle(
								fontSize: 11,
								fontWeight: FontWeight.bold,
								color: Colors.grey,
							),
						),
					),
					const SizedBox(width: 6),
					Expanded(
						child: Text(
							value,
							maxLines: maxLines,
							overflow: TextOverflow.ellipsis,
							style: const TextStyle(
								fontSize: 12,
								fontWeight: FontWeight.w600,
								color: Colors.black87,
								height: 1.15,
							),
						),
					),
				],
			);
		}

		return Container(
			decoration: BoxDecoration(
				color: Colors.white,
				borderRadius: BorderRadius.circular(8),
			),
			padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.start,
				children: [
					const Text(
						'공연 정보',
						style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
					),
					const SizedBox(height: 8),
					Expanded(
						child: LayoutBuilder(
							builder: (context, constraints) {
								// 값이 길어져도(예: 공연장/좌석 줄바꿈) 티켓 영역 밖으로 오버플로우가 나지 않게
								// 가용 높이에 맞춰 '필요할 때만' 자동 축소합니다.
								return FittedBox(
									fit: BoxFit.scaleDown,
									alignment: Alignment.centerLeft,
									child: SizedBox(
										width: constraints.maxWidth,
										child: Row(
											children: [
												Expanded(
													child: Column(
														mainAxisAlignment: MainAxisAlignment.center,
														children: [
															infoRow('날짜', date),
															const SizedBox(height: 4),
															infoRow('시간', time),
															const SizedBox(height: 4),
															infoRow('공연장', venue, maxLines: 2),
														],
													),
												),
												Container(
													width: 1,
													margin: const EdgeInsets.symmetric(vertical: 4),
													color: Colors.black.withValues(alpha: 0.10),
												),
												Expanded(
													child: Column(
														mainAxisAlignment: MainAxisAlignment.center,
														children: [
															infoRow('좌석', seat, maxLines: 2),
															const SizedBox(height: 4),
															infoRow('가격', price),
														],
													),
												),
											],
										),
									),
								);
							},
						),
					),
				],
			),
		);
	}

  /// 공연 전 티켓 UI
  Widget _buildTicketBeforeConcert() {
	return Row(
	  children: [
		Expanded(
		  flex: 3,
		  child: Container(
			decoration: const BoxDecoration(
			  color: Colors.white,
			  borderRadius: BorderRadius.horizontal(left: Radius.circular(8)),
			),
			padding: const EdgeInsets.all(12),
			child: const Column(
			  crossAxisAlignment: CrossAxisAlignment.start,
			  children: [
				Text("공연전", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
				Expanded(
				  child: Center(
					child: Text("공연전", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
				  ),
				),
			  ],
			),
		  ),
		),
		Container(width: 1, color: Colors.grey.shade400),
		Expanded(
		  flex: 1,
		  child: Container(
			decoration: const BoxDecoration(
			  color: Colors.white,
			  borderRadius: BorderRadius.horizontal(right: Radius.circular(8)),
			),
		  ),
		),
	  ],
	);
  }

  /// 공연 후 티켓 UI
  Widget _buildTicketAfterConcert(BuildContext context) {
	final revealedBeforeCell = PressableScale(
		onTap: _isAddTicketExpanded
			? null
			: () {
				final startRect = _globalRectOf(_concertBeforeShortcutKey);
				if (startRect == null) return;

				// 공연 후 티켓에서 '공연전' 칸을 눌러도 동일한 오버레이 확장 애니메이션 실행
				ConcertBeforeOverlay.show(
					context,
					startRect: startRect,
					collapsedTicket: _concertBeforeShortcutWidget(dark: true),
					concertTitle: '공연전',
				);
			},
		pressScale: 0.985,
		tapScale: 1.03,
		child: KeyedSubtree(
			key: _concertBeforeShortcutKey,
			child: _concertBeforeShortcutWidget(dark: true),
		),
	);

	return TearToRevealRight(
		enabled: !_isAddTicketExpanded,
		borderRadius: BorderRadius.circular(8),
		borderColor: Colors.grey.shade300,
		leftFlex: 3,
		rightFlex: 1,
		perforationWidth: 8,
		tearThreshold: 0.35,
		leftChild: Padding(
			padding: const EdgeInsets.all(12),
			child: const Column(
				crossAxisAlignment: CrossAxisAlignment.start,
				children: [
					Text(
						"공연후",
						style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
					),
					Expanded(
						child: Center(
							child: Text(
								"공연후",
								style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
							),
						),
					),
				],
			),
		),
		/// 뜯기 전: 오른쪽 조각(입장 시 뜯어가는 부분)
		rightTearable: _concertAfterTearPieceWidget(),
		/// 뜯기 후: 오른쪽 자리에는 '공연전' 칸이 남도록
		rightRevealed: revealedBeforeCell,
	);
  }

  /// 공연 후 티켓 우측의 '공연전' 바로가기 UI(오버레이의 collapsedTicket에도 그대로 재사용)
  Widget _concertBeforeShortcutWidget({bool dark = false}) {
	// NOTE: 이 위젯은 공연 후 티켓의 '뜯긴 자리'에 남는 칸이기도 하고,
	//       오버레이 애니메이션 시작 시(collapsedTicket)에도 그대로 사용됩니다.
	return Container(
		// 요구사항: 뜯긴 후 남는 공연전 칸은 포켓(겉의 반투명 흰색)보다
		// '살짝만' 어두운 톤으로 유지
		color: dark ? const Color(0xFFE6E6E6) : Colors.white,
		child: Center(
			child: Text(
				"공연전",
				style: TextStyle(
					fontSize: 12,
					fontWeight: FontWeight.w800,
					color: dark ? Colors.black54 : Colors.black54,
				),
			),
		),
	);
  }
}


