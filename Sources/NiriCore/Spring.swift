import Foundation

/// Mola criticamente amortecida (mesmo modelo do niri: damping-ratio 1.0, massa 1).
///
/// O valor é calculado pela fórmula fechada, não por integração frame a frame,
/// então um frame atrasado não muda a trajetória. Trocar o alvo no meio do caminho
/// preserva a velocidade atual: segurar a tecla não dá tranco.
public struct Spring {
    public private(set) var target: Double
    private var from: Double
    private var velocity0: Double
    private var start: Double
    public let stiffness: Double

    public init(_ value: Double, stiffness: Double = 800) {
        self.target = value
        self.from = value
        self.velocity0 = 0
        self.start = 0
        self.stiffness = stiffness
    }

    private var omega: Double { stiffness.squareRoot() }

    public func value(at t: Double) -> Double {
        let dt = max(0, t - start)
        let d0 = from - target
        return target + (d0 + (velocity0 + omega * d0) * dt) * exp(-omega * dt)
    }

    public func velocity(at t: Double) -> Double {
        let dt = max(0, t - start)
        let d0 = from - target
        return (velocity0 - omega * (velocity0 + omega * d0) * dt) * exp(-omega * dt)
    }

    /// Parado quando falta menos de meio ponto e a velocidade é desprezível.
    public func isSettled(at t: Double) -> Bool {
        abs(value(at: t) - target) < 0.5 && abs(velocity(at: t)) < 5
    }

    /// Falta menos de `d` pra chegar (sem olhar a velocidade).
    public func isNear(at t: Double, within d: Double) -> Bool { abs(value(at: t) - target) < d }

    /// Novo alvo, partindo da posição e velocidade atuais.
    public mutating func retarget(_ newTarget: Double, at t: Double) {
        guard newTarget != target else { return }
        let v = value(at: t)
        velocity0 = velocity(at: t)
        from = v
        start = t
        target = newTarget
    }

    /// Soma `d` à posição atual e anima de volta pro alvo. Usado quando a coluna muda de lugar
    /// no modelo mas precisa continuar visualmente onde estava.
    public mutating func displace(by d: Double, at t: Double) {
        let v = value(at: t)
        velocity0 = velocity(at: t)
        from = v + d
        start = t
    }

    /// Translada a animação inteira (posição e alvo). Nada muda visualmente.
    public mutating func shift(by d: Double) {
        from += d
        target += d
    }

    public mutating func snap() {
        from = target
        velocity0 = 0
    }
}
