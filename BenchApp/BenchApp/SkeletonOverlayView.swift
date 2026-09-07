import SwiftUI
import RunnerPoseKit

/// Optional visual sanity check — draw the 23 joints + skeleton over a frame
/// (規劃書 §03 疊圖預覽). Not wired into the run flow; call it from a debug screen
/// with a captured `(UIImage, RunnerPose)` pair.
struct SkeletonOverlayView: View {
    let image: UIImage
    let pose: RunnerPose

    /// COCO-17 limb pairs + foot links.
    static let bones: [(JointName, JointName)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip), (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.leftAnkle, .leftHeel), (.leftAnkle, .leftBigToe), (.leftBigToe, .leftSmallToe),
        (.rightAnkle, .rightHeel), (.rightAnkle, .rightBigToe), (.rightBigToe, .rightSmallToe),
    ]

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / image.size.width, geo.size.height / image.size.height)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().scaledToFit()
                Canvas { ctx, _ in
                    func p(_ j: Joint) -> CGPoint { CGPoint(x: j.x * scale, y: j.y * scale) }
                    let byName = Dictionary(uniqueKeysWithValues: pose.joints.map { ($0.name, $0) })
                    for (a, b) in Self.bones {
                        guard let ja = byName[a], let jb = byName[b] else { continue }
                        var path = Path()
                        path.move(to: p(ja)); path.addLine(to: p(jb))
                        ctx.stroke(path, with: .color(.green), lineWidth: 2)
                    }
                    for j in pose.joints {
                        let r = CGRect(x: j.x * scale - 3, y: j.y * scale - 3, width: 6, height: 6)
                        ctx.fill(Path(ellipseIn: r), with: .color(j.score > 0.3 ? .yellow : .gray))
                    }
                }
            }
        }
    }
}
