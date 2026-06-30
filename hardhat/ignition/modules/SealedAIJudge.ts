import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("SealedAIJudgeModule", (m) => {
  const sealedAIJudge = m.contract("SealedAIJudge");

  return { sealedAIJudge };
});
